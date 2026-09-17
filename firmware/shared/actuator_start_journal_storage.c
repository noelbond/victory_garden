#include "actuator_start_journal_storage.h"

#include <limits.h>
#include <string.h>

typedef enum {
    BANK_ERASED = 0,
    BANK_VALID,
    BANK_INVALID,
    BANK_UNSUPPORTED,
} bank_result_t;

typedef struct {
    bank_result_t result;
    bool header_was_valid;
    vg_actuator_start_journal_flash_bank_header_t header;
    uint64_t high_water;
    size_t record_count;
    vg_actuator_start_journal_flash_accepted_record_t records[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
} bank_scan_t;

static bool backend_is_valid(const vg_actuator_start_journal_storage_backend_t *backend) {
    return backend && backend->read_page && backend->program_page && backend->erase_sector;
}

static bool read_page(const vg_actuator_start_journal_storage_t *storage, size_t bank, size_t page,
                      uint8_t output[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    return storage && storage->backend.read_page &&
           storage->backend.read_page(storage->backend.context, bank, page, output);
}

static bool page_is_erased(const vg_actuator_start_journal_storage_t *storage, size_t bank, size_t page) {
    uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    return read_page(storage, bank, page, bytes) &&
           vg_actuator_start_journal_flash_page_is_erased(bytes);
}

static bool bank_is_erased(const vg_actuator_start_journal_storage_t *storage, size_t bank) {
    for (size_t page = 0; page < VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK; ++page) {
        if (!page_is_erased(storage, bank, page)) {
            return false;
        }
    }
    return true;
}

static bool records_match(const vg_actuator_start_journal_flash_accepted_record_t *left,
                          const vg_actuator_start_journal_flash_accepted_record_t *right) {
    return left->sequence == right->sequence &&
           left->accepted_record.accepted == right->accepted_record.accepted &&
           left->accepted_record.version == right->accepted_record.version &&
           left->accepted_record.irrigation_line == right->accepted_record.irrigation_line &&
           left->accepted_record.issued_at_epoch_seconds == right->accepted_record.issued_at_epoch_seconds &&
           strcmp(left->accepted_record.idempotency_key, right->accepted_record.idempotency_key) == 0 &&
           strcmp(left->accepted_record.zone_id, right->accepted_record.zone_id) == 0 &&
           strcmp(left->accepted_record.node_id, right->accepted_record.node_id) == 0;
}

static bool scan_records(const vg_actuator_start_journal_storage_t *storage, size_t bank,
                         bank_scan_t *scan) {
    bool saw_erased = false;
    uint64_t previous_sequence = 0;
    scan->high_water = scan->header.sequence_high_water_mark;

    for (size_t offset = 0; offset < VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT; ++offset) {
        uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
        vg_actuator_start_journal_flash_accepted_record_t decoded;
        if (!read_page(storage, bank, VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE + offset,
                       bytes)) {
            return false;
        }
        const vg_actuator_start_journal_flash_page_result_t result =
            vg_actuator_start_journal_flash_decode_accepted_record(bytes, &decoded);
        if (result == VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_ERASED) {
            saw_erased = true;
            continue;
        }
        if (result != VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID || saw_erased || decoded.sequence == 0u ||
            (scan->record_count > 0u && decoded.sequence <= previous_sequence)) {
            scan->result = result == VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED
                               ? BANK_UNSUPPORTED
                               : BANK_INVALID;
            return true;
        }
        for (size_t prior = 0; prior < scan->record_count; ++prior) {
            if (strcmp(scan->records[prior].accepted_record.idempotency_key,
                       decoded.accepted_record.idempotency_key) == 0) {
                scan->result = BANK_INVALID;
                return true;
            }
        }
        scan->records[scan->record_count++] = decoded;
        previous_sequence = decoded.sequence;
        if (decoded.sequence > scan->high_water) {
            scan->high_water = decoded.sequence;
        }
    }

    for (size_t page = VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RESERVED_PAGE;
         page < VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK; ++page) {
        if (!page_is_erased(storage, bank, page)) {
            scan->result = BANK_INVALID;
            return true;
        }
    }
    scan->result = BANK_VALID;
    return true;
}

static bank_scan_t scan_bank(const vg_actuator_start_journal_storage_t *storage, size_t bank) {
    bank_scan_t scan;
    memset(&scan, 0, sizeof(scan));
    if (bank_is_erased(storage, bank)) {
        scan.result = BANK_ERASED;
        return scan;
    }

    uint8_t header_page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    if (!read_page(storage, bank, VG_ACTUATOR_START_JOURNAL_STORAGE_HEADER_PAGE, header_page)) {
        scan.result = BANK_INVALID;
        return scan;
    }
    const vg_actuator_start_journal_flash_page_result_t header_result =
        vg_actuator_start_journal_flash_decode_bank_header(header_page, &scan.header);
    if (header_result == VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED) {
        scan.result = BANK_UNSUPPORTED;
        return scan;
    }
    if (header_result != VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID || scan.header.generation == 0u) {
        scan.result = BANK_INVALID;
        return scan;
    }
    scan.header_was_valid = true;
    if (!scan_records(storage, bank, &scan)) {
        scan.result = BANK_INVALID;
    }
    return scan;
}

static bool newer_is_valid_successor(const bank_scan_t *newer, const bank_scan_t *older) {
    if (older->header.generation == UINT64_MAX ||
        newer->header.generation != older->header.generation + 1u ||
        newer->header.sequence_high_water_mark != older->high_water) {
        return false;
    }
    for (size_t index = 0; index < newer->record_count; ++index) {
        // Records at or below the old high-water were copied during
        // compaction and must exactly match old durable history. Higher
        // records can only be immutable appends made after the new header
        // became authoritative while old-bank cleanup remained pending.
        if (newer->records[index].sequence > older->high_water) {
            continue;
        }
        bool found = false;
        for (size_t old_index = 0; old_index < older->record_count; ++old_index) {
            if (records_match(&newer->records[index], &older->records[old_index])) {
                found = true;
                break;
            }
        }
        if (!found) {
            return false;
        }
    }
    return true;
}

static void load_authority(vg_actuator_start_journal_storage_t *storage, size_t bank,
                           const bank_scan_t *scan, bool cleanup_required) {
    storage->authoritative_bank = bank;
    storage->header = scan->header;
    storage->current_high_water = scan->high_water;
    storage->record_count = scan->record_count;
    memcpy(storage->records, scan->records, sizeof(storage->records));
    memset(storage->logical_records, 0, sizeof(storage->logical_records));
    for (size_t index = 0; index < scan->record_count; ++index) {
        storage->logical_records[index] = scan->records[index].accepted_record;
    }
    (void)vg_actuator_start_journal_init(&storage->logical_journal, storage->logical_records,
                                         VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT);
    storage->state = cleanup_required
                         ? VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED
                         : (scan->record_count == 0u
                                ? VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY
                                : VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
}

vg_actuator_start_journal_storage_state_t vg_actuator_start_journal_storage_open(
    vg_actuator_start_journal_storage_t *storage,
    const vg_actuator_start_journal_storage_backend_t *backend
) {
    if (!storage || !backend_is_valid(backend)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT;
    }
    memset(storage, 0, sizeof(*storage));
    storage->backend = *backend;
    storage->authoritative_bank = VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT;

    const bank_scan_t first = scan_bank(storage, 0u);
    const bank_scan_t second = scan_bank(storage, 1u);
    const size_t valid_count = (first.result == BANK_VALID ? 1u : 0u) +
                               (second.result == BANK_VALID ? 1u : 0u);
    if (first.result == BANK_ERASED && second.result == BANK_ERASED) {
        storage->state = VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK;
        return storage->state;
    }
    if (valid_count == 0u) {
        storage->state = first.result == BANK_UNSUPPORTED || second.result == BANK_UNSUPPORTED
                             ? VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED
                             : VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT;
        return storage->state;
    }
    if (valid_count == 1u) {
        const bool first_is_valid = first.result == BANK_VALID;
        const bank_scan_t *authority = first_is_valid ? &first : &second;
        const bank_scan_t *other = first_is_valid ? &second : &first;
        // A valid header with malformed contents is an authority claim, not
        // harmless inactive debris, so do not guess which history to trust.
        if (other->header_was_valid) {
            storage->state = other->result == BANK_UNSUPPORTED
                                 ? VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED
                                 : VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT;
            return storage->state;
        }
        load_authority(storage, first_is_valid ? 0u : 1u, authority,
                       other->result != BANK_ERASED);
        return storage->state;
    }

    const bank_scan_t *newer = first.header.generation > second.header.generation ? &first : &second;
    const bank_scan_t *older = newer == &first ? &second : &first;
    if (first.header.generation == second.header.generation || !newer_is_valid_successor(newer, older)) {
        storage->state = VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT;
        return storage->state;
    }
    load_authority(storage, newer == &first ? 0u : 1u, newer, true);
    return storage->state;
}

bool vg_actuator_start_journal_storage_is_start_enabled(
    const vg_actuator_start_journal_storage_t *storage
) {
    return storage && (storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY ||
                       storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS ||
                       storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
}

static bool storage_is_initialized(const vg_actuator_start_journal_storage_t *storage) {
    return storage && storage->authoritative_bank < VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT &&
           vg_actuator_start_journal_storage_is_start_enabled(storage);
}

// open() intentionally clears volatile reconstructed state before loading it.
// Keep the callback triple in a local value so its source is never cleared
// while being copied back into the manager.
static vg_actuator_start_journal_storage_state_t rescan(
    vg_actuator_start_journal_storage_t *storage
) {
    const vg_actuator_start_journal_storage_backend_t backend = storage->backend;
    return vg_actuator_start_journal_storage_open(storage, &backend);
}

static vg_actuator_start_journal_storage_result_t rescan_after_mutation_failure(
    vg_actuator_start_journal_storage_t *storage,
    vg_actuator_start_journal_storage_result_t result
) {
    (void)rescan(storage);
    return result;
}

static vg_actuator_start_journal_storage_result_t program_and_verify_record(
    vg_actuator_start_journal_storage_t *storage, size_t bank, size_t page,
    const vg_actuator_start_journal_flash_accepted_record_t *expected
) {
    uint8_t encoded[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    uint8_t actual[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    vg_actuator_start_journal_flash_accepted_record_t decoded;
    if (!vg_actuator_start_journal_flash_encode_accepted_record(expected, encoded)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_ARGUMENT;
    }
    if (!storage->backend.program_page(storage->backend.context, bank, page, encoded)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE;
    }
    if (!read_page(storage, bank, page, actual) ||
        vg_actuator_start_journal_flash_decode_accepted_record(actual, &decoded) !=
            VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID ||
        !records_match(&decoded, expected)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE;
    }
    return VG_ACTUATOR_START_JOURNAL_STORAGE_OK;
}

vg_actuator_start_journal_storage_result_t vg_actuator_start_journal_storage_initialize(
    vg_actuator_start_journal_storage_t *storage
) {
    if (!storage || storage->state != VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK ||
        !bank_is_erased(storage, 0u) || !bank_is_erased(storage, 1u)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_BLANK;
    }
    const vg_actuator_start_journal_flash_bank_header_t header = {
        .generation = 1u,
        .sequence_high_water_mark = 0u,
        .record_page_size = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
        .logical_capacity = VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY,
    };
    uint8_t encoded[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    uint8_t actual[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    vg_actuator_start_journal_flash_bank_header_t decoded;
    if (!vg_actuator_start_journal_flash_encode_bank_header(&header, encoded)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_ARGUMENT;
    }
    if (!storage->backend.program_page(storage->backend.context, 0u,
                                       VG_ACTUATOR_START_JOURNAL_STORAGE_HEADER_PAGE, encoded)) {
        return rescan_after_mutation_failure(storage,
                                             VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
    }
    if (!read_page(storage, 0u, VG_ACTUATOR_START_JOURNAL_STORAGE_HEADER_PAGE, actual) ||
        vg_actuator_start_journal_flash_decode_bank_header(actual, &decoded) !=
            VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID ||
        decoded.generation != header.generation ||
        decoded.sequence_high_water_mark != header.sequence_high_water_mark) {
        return rescan_after_mutation_failure(storage,
                                             VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE);
    }
    return rescan(storage) ==
                   VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY
               ? VG_ACTUATOR_START_JOURNAL_STORAGE_OK
               : VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE;
}

vg_actuator_start_journal_storage_result_t vg_actuator_start_journal_storage_append_verified(
    vg_actuator_start_journal_storage_t *storage,
    const vg_actuator_start_journal_record_t *record,
    uint64_t *sequence_out
) {
    if (!storage || !record || !sequence_out || !storage_is_initialized(storage) ||
        !vg_actuator_start_journal_record_is_valid(record)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_READY;
    }
    if (storage->record_count == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_FULL;
    }
    if (storage->current_high_water == UINT64_MAX) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_SEQUENCE_EXHAUSTED;
    }
    for (size_t index = 0; index < storage->record_count; ++index) {
        if (strcmp(storage->records[index].accepted_record.idempotency_key,
                   record->idempotency_key) == 0) {
            return VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_ARGUMENT;
        }
    }
    const size_t page = VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE + storage->record_count;
    if (!page_is_erased(storage, storage->authoritative_bank, page)) {
        return rescan_after_mutation_failure(storage,
                                             VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE);
    }
    const vg_actuator_start_journal_flash_accepted_record_t candidate = {
        .sequence = storage->current_high_water + 1u,
        .accepted_record = *record,
    };
    const vg_actuator_start_journal_storage_result_t result =
        program_and_verify_record(storage, storage->authoritative_bank, page, &candidate);
    if (result != VG_ACTUATOR_START_JOURNAL_STORAGE_OK) {
        return rescan_after_mutation_failure(storage, result);
    }
    storage->records[storage->record_count] = candidate;
    ++storage->record_count;
    storage->current_high_water = candidate.sequence;
    storage->state = storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED
                         ? VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED
                         : VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS;
    *sequence_out = candidate.sequence;
    return VG_ACTUATOR_START_JOURNAL_STORAGE_OK;
}

static bool retained_snapshot_is_valid(const vg_actuator_start_journal_storage_t *storage,
                                       const vg_actuator_start_journal_flash_accepted_record_t *retained,
                                       size_t retained_count) {
    if (retained_count > storage->record_count || (retained_count != 0u && !retained)) {
        return false;
    }
    uint64_t previous_sequence = 0;
    for (size_t index = 0; index < retained_count; ++index) {
        if (retained[index].sequence == 0u ||
            (index > 0u && retained[index].sequence <= previous_sequence)) {
            return false;
        }
        bool found = false;
        for (size_t original = 0; original < storage->record_count; ++original) {
            if (records_match(&retained[index], &storage->records[original])) {
                found = true;
                break;
            }
        }
        if (!found) {
            return false;
        }
        previous_sequence = retained[index].sequence;
    }
    return true;
}

static vg_actuator_start_journal_storage_result_t erase_bank(
    vg_actuator_start_journal_storage_t *storage, size_t bank
) {
    for (size_t sector = 0; sector < VG_ACTUATOR_START_JOURNAL_STORAGE_SECTORS_PER_BANK; ++sector) {
        if (!storage->backend.erase_sector(storage->backend.context, bank, sector)) {
            return VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE;
        }
    }
    return bank_is_erased(storage, bank) ? VG_ACTUATOR_START_JOURNAL_STORAGE_OK
                                         : VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE;
}

vg_actuator_start_journal_storage_result_t vg_actuator_start_journal_storage_cleanup_inactive(
    vg_actuator_start_journal_storage_t *storage
) {
    if (!storage_is_initialized(storage)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_READY;
    }
    const size_t inactive = storage->authoritative_bank == 0u ? 1u : 0u;
    const vg_actuator_start_journal_storage_result_t result = erase_bank(storage, inactive);
    if (result != VG_ACTUATOR_START_JOURNAL_STORAGE_OK) {
        return rescan_after_mutation_failure(storage, result);
    }
    const vg_actuator_start_journal_storage_state_t state =
        rescan(storage);
    return state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY ||
                   state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS
               ? VG_ACTUATOR_START_JOURNAL_STORAGE_OK
               : VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE;
}

vg_actuator_start_journal_storage_result_t vg_actuator_start_journal_storage_compact(
    vg_actuator_start_journal_storage_t *storage,
    const vg_actuator_start_journal_flash_accepted_record_t *retained,
    size_t retained_count
) {
    if (!storage_is_initialized(storage)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_READY;
    }
    if (storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED;
    }
    if (!retained_snapshot_is_valid(storage, retained, retained_count)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_RETAINED_SNAPSHOT;
    }
    if (retained_count == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_FULL;
    }
    if (storage->header.generation == UINT64_MAX) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_GENERATION_EXHAUSTED;
    }

    const size_t old_bank = storage->authoritative_bank;
    const size_t new_bank = old_bank == 0u ? 1u : 0u;
    vg_actuator_start_journal_storage_result_t result = erase_bank(storage, new_bank);
    if (result != VG_ACTUATOR_START_JOURNAL_STORAGE_OK) {
        return rescan_after_mutation_failure(storage, result);
    }
    for (size_t index = 0; index < retained_count; ++index) {
        result = program_and_verify_record(storage, new_bank,
                                           VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE + index,
                                           &retained[index]);
        if (result != VG_ACTUATOR_START_JOURNAL_STORAGE_OK) {
            return rescan_after_mutation_failure(storage, result);
        }
    }
    const vg_actuator_start_journal_flash_bank_header_t header = {
        .generation = storage->header.generation + 1u,
        .sequence_high_water_mark = storage->current_high_water,
        .record_page_size = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
        .logical_capacity = VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY,
    };
    uint8_t encoded[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    uint8_t actual[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    vg_actuator_start_journal_flash_bank_header_t decoded;
    if (!vg_actuator_start_journal_flash_encode_bank_header(&header, encoded)) {
        return VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_ARGUMENT;
    }
    if (!storage->backend.program_page(storage->backend.context, new_bank,
                                       VG_ACTUATOR_START_JOURNAL_STORAGE_HEADER_PAGE, encoded)) {
        return rescan_after_mutation_failure(storage,
                                             VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
    }
    if (!read_page(storage, new_bank, VG_ACTUATOR_START_JOURNAL_STORAGE_HEADER_PAGE, actual) ||
        vg_actuator_start_journal_flash_decode_bank_header(actual, &decoded) !=
            VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID ||
        decoded.generation != header.generation ||
        decoded.sequence_high_water_mark != header.sequence_high_water_mark) {
        return rescan_after_mutation_failure(storage,
                                             VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE);
    }
    // Header verification is the authority transition. Old-bank erase is only
    // cleanup; failure cannot revoke the new durable authority.
    result = erase_bank(storage, old_bank);
    if (result != VG_ACTUATOR_START_JOURNAL_STORAGE_OK) {
        (void)rescan(storage);
        return VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED;
    }
    const vg_actuator_start_journal_storage_state_t state =
        rescan(storage);
    return state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY ||
                   state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS
               ? VG_ACTUATOR_START_JOURNAL_STORAGE_OK
               : VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE;
}
