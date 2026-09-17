#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "actuator_start_journal_storage.h"
#include "simulated_flash_backend.h"

#define HEADER_LAYOUT_VERSION_OFFSET 4u
#define RECORD_LAYOUT_VERSION_OFFSET 4u
#define CRC_OFFSET 248u
#define CRC_INVERSE_OFFSET 252u

static void write_u32_le(uint8_t *bytes, uint32_t value) {
    for (size_t index = 0; index < 4u; ++index) {
        bytes[index] = (uint8_t)(value >> (index * 8u));
    }
}

static void refresh_integrity(uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    const uint32_t crc = vg_actuator_start_journal_flash_crc32(page, CRC_OFFSET);
    write_u32_le(page + CRC_OFFSET, crc);
    write_u32_le(page + CRC_INVERSE_OFFSET, ~crc);
}

static vg_actuator_start_journal_record_t record_for(unsigned int number) {
    vg_actuator_start_journal_record_t record;
    memset(&record, 0, sizeof(record));
    record.accepted = true;
    record.version = VG_ACTUATOR_START_JOURNAL_RECORD_VERSION;
    record.irrigation_line = (uint8_t)((number % 4u) + 1u);
    record.issued_at_epoch_seconds = 1700000000 + (int64_t)number;
    assert(snprintf(record.idempotency_key, sizeof(record.idempotency_key), "key-%u", number) > 0);
    assert(snprintf(record.zone_id, sizeof(record.zone_id), "zone-%u", number) > 0);
    assert(snprintf(record.node_id, sizeof(record.node_id), "node-%u", number) > 0);
    return record;
}

static vg_actuator_start_journal_storage_backend_t interface_for(vg_simulated_flash_backend_t *flash) {
    return vg_simulated_flash_backend_interface(flash);
}

static void initialize(vg_simulated_flash_backend_t *flash, vg_actuator_start_journal_storage_t *storage) {
    const vg_actuator_start_journal_storage_backend_t backend = interface_for(flash);
    assert(vg_actuator_start_journal_storage_open(storage, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
    assert(vg_actuator_start_journal_storage_initialize(storage) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
    assert(storage->header.generation == 1u);
    assert(storage->current_high_water == 0u);
}

static bool contains_sequence(const vg_actuator_start_journal_storage_t *storage, uint64_t sequence) {
    for (size_t index = 0; index < storage->record_count; ++index) {
        if (storage->records[index].sequence == sequence) {
            return true;
        }
    }
    return false;
}

// Central crash-safety assertion: a prior durable record either remains
// reconstructed or the manager has disabled future START admission.
static void assert_history_or_locked(const vg_actuator_start_journal_storage_t *storage,
                                     const uint64_t *required_sequences, size_t required_count) {
    if (!vg_actuator_start_journal_storage_is_start_enabled(storage)) {
        assert(storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT ||
               storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED);
        return;
    }
    for (size_t index = 0; index < required_count; ++index) {
        assert(contains_sequence(storage, required_sequences[index]));
    }
}

static vg_actuator_start_journal_storage_state_t reboot(vg_simulated_flash_backend_t *flash,
                                                         vg_actuator_start_journal_storage_t *storage) {
    const vg_actuator_start_journal_storage_backend_t backend = interface_for(flash);
    return vg_actuator_start_journal_storage_open(storage, &backend);
}

static void test_simulated_nor_semantics(void) {
    vg_simulated_flash_backend_t flash;
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    vg_simulated_flash_backend_init(&flash);
    const vg_actuator_start_journal_storage_backend_t backend = interface_for(&flash);
    memset(page, 0xA5, sizeof(page));
    assert(backend.program_page(backend.context, 0u, 0u, page));
    assert(!backend.program_page(backend.context, 0u, 0u, page));
    assert(backend.erase_sector(backend.context, 0u, 0u));
    assert(backend.program_page(backend.context, 0u, 0u, page));
}

static void test_blank_initialization_and_reconstruction(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_actuator_start_journal_storage_t recovered;
    vg_simulated_flash_backend_init(&flash);
    initialize(&flash, &storage);

    const vg_actuator_start_journal_record_t record = record_for(1u);
    vg_actuator_start_journal_candidate_t candidate;
    assert(vg_actuator_start_journal_prepare(
               &storage.logical_journal, record.idempotency_key, record.zone_id,
               record.node_id, record.irrigation_line, record.issued_at_epoch_seconds,
               &candidate
           ) == VG_ACTUATOR_START_JOURNAL_NEW);
    uint64_t sequence = 0;
    assert(vg_actuator_start_journal_storage_append_verified(
               &storage, &candidate.record, &sequence
           ) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(sequence == 1u);
    // Storage has verified physical bytes, but accepted RAM history changes
    // only at the caller-controlled commit boundary.
    assert(vg_actuator_start_journal_commit_verified(&storage.logical_journal, &candidate));
    assert(vg_actuator_start_journal_prepare(
               &storage.logical_journal, record.idempotency_key, record.zone_id,
               record.node_id, record.irrigation_line, record.issued_at_epoch_seconds,
               &candidate
           ) == VG_ACTUATOR_START_JOURNAL_DUPLICATE);
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    assert(recovered.current_high_water == 1u);
    assert(recovered.record_count == 1u);
    vg_actuator_start_journal_candidate_t recovered_candidate;
    assert(vg_actuator_start_journal_prepare(&recovered.logical_journal, record.idempotency_key,
                                              record.zone_id, record.node_id,
                                              record.irrigation_line,
                                              record.issued_at_epoch_seconds, &recovered_candidate) ==
           VG_ACTUATOR_START_JOURNAL_DUPLICATE);
}

static void test_initialization_power_cuts(void) {
    static const vg_simulated_flash_fault_t faults[] = {
        VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM,
        VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM,
        VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM,
    };
    for (size_t index = 0; index < sizeof(faults) / sizeof(faults[0]); ++index) {
        vg_simulated_flash_backend_t flash;
        vg_actuator_start_journal_storage_t storage;
        vg_actuator_start_journal_storage_t recovered;
        vg_simulated_flash_backend_init(&flash);
        const vg_actuator_start_journal_storage_backend_t backend = interface_for(&flash);
        assert(vg_actuator_start_journal_storage_open(&storage, &backend) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
        vg_simulated_flash_backend_set_fault(&flash, faults[index], 1u, 73u);
        assert(vg_actuator_start_journal_storage_initialize(&storage) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
        vg_simulated_flash_backend_clear_fault(&flash);
        const vg_actuator_start_journal_storage_state_t state = reboot(&flash, &recovered);
        if (faults[index] == VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM) {
            assert(state == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
        } else if (faults[index] == VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM) {
            assert(state == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);
        } else {
            assert(state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
        }
    }
}

static void test_append_power_cuts(void) {
    static const vg_simulated_flash_fault_t faults[] = {
        VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM,
        VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM,
        VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM,
    };
    const vg_actuator_start_journal_record_t record = record_for(9u);
    for (size_t index = 0; index < sizeof(faults) / sizeof(faults[0]); ++index) {
        vg_simulated_flash_backend_t flash;
        vg_actuator_start_journal_storage_t storage;
        vg_actuator_start_journal_storage_t recovered;
        vg_simulated_flash_backend_init(&flash);
        initialize(&flash, &storage);
        vg_simulated_flash_backend_set_fault(&flash, faults[index], 1u, 131u);
        uint64_t sequence = 0;
        assert(vg_actuator_start_journal_storage_append_verified(&storage, &record, &sequence) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
        vg_simulated_flash_backend_clear_fault(&flash);
        const vg_actuator_start_journal_storage_state_t state = reboot(&flash, &recovered);
        if (faults[index] == VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM) {
            assert(state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
            assert(recovered.record_count == 0u);
        } else if (faults[index] == VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM) {
            assert(state == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);
            assert(!vg_actuator_start_journal_storage_is_start_enabled(&recovered));
            assert(storage.state == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);
        } else {
            assert(state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
            assert(recovered.record_count == 1u);
            assert(recovered.records[0].sequence == 1u);
        }
    }
}

static void test_duplicate_and_exhausted_boundaries(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_simulated_flash_backend_init(&flash);
    initialize(&flash, &storage);
    const vg_actuator_start_journal_record_t first = record_for(1u);
    uint64_t sequence = 0;
    assert(vg_actuator_start_journal_storage_append_verified(&storage, &first, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(vg_actuator_start_journal_storage_append_verified(&storage, &first, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_ARGUMENT);

    vg_simulated_flash_backend_init(&flash);
    const vg_actuator_start_journal_flash_bank_header_t high_water_header = {
        .generation = 1u,
        .sequence_high_water_mark = UINT64_MAX,
        .record_page_size = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
        .logical_capacity = VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY,
    };
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    assert(vg_actuator_start_journal_flash_encode_bank_header(&high_water_header, page));
    const vg_actuator_start_journal_storage_backend_t backend = interface_for(&flash);
    assert(backend.program_page(backend.context, 0u, 0u, page));
    assert(reboot(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
    assert(vg_actuator_start_journal_storage_append_verified(&storage, &first, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_SEQUENCE_EXHAUSTED);

    vg_simulated_flash_backend_init(&flash);
    const vg_actuator_start_journal_flash_bank_header_t generation_header = {
        .generation = UINT64_MAX,
        .sequence_high_water_mark = 0u,
        .record_page_size = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
        .logical_capacity = VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY,
    };
    assert(vg_actuator_start_journal_flash_encode_bank_header(&generation_header, page));
    assert(backend.program_page(backend.context, 0u, 0u, page));
    assert(reboot(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
    assert(vg_actuator_start_journal_storage_compact(&storage, NULL, 0u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_GENERATION_EXHAUSTED);
}

static void setup_four_records(vg_simulated_flash_backend_t *flash,
                               vg_actuator_start_journal_storage_t *storage) {
    vg_simulated_flash_backend_init(flash);
    initialize(flash, storage);
    for (unsigned int number = 1u; number <= 4u; ++number) {
        const vg_actuator_start_journal_record_t record = record_for(number);
        uint64_t sequence = 0;
        assert(vg_actuator_start_journal_storage_append_verified(storage, &record, &sequence) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
        assert(sequence == number);
    }
    assert(storage->current_high_water == 4u);
}

static void test_empty_and_partial_compaction_high_water(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_actuator_start_journal_storage_t recovered;
    setup_four_records(&flash, &storage);
    assert(vg_actuator_start_journal_storage_compact(&storage, NULL, 0u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(storage.header.generation == 2u);
    assert(storage.header.sequence_high_water_mark == 4u);
    assert(storage.record_count == 0u);
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
    assert(recovered.current_high_water == 4u);
    const vg_actuator_start_journal_record_t fifth = record_for(5u);
    uint64_t sequence = 0;
    assert(vg_actuator_start_journal_storage_append_verified(&recovered, &fifth, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(sequence == 5u);

    setup_four_records(&flash, &storage);
    const vg_actuator_start_journal_flash_accepted_record_t retained = storage.records[1];
    assert(vg_actuator_start_journal_storage_compact(&storage, &retained, 1u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(storage.record_count == 1u);
    assert(storage.records[0].sequence == 2u);
    assert(storage.header.sequence_high_water_mark == 4u);
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    assert(recovered.current_high_water == 4u);
    sequence = 0;
    assert(vg_actuator_start_journal_storage_append_verified(&recovered, &fifth, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(sequence == 5u);
}

static void test_header_last_authority(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_actuator_start_journal_storage_t recovered;
    uint64_t old_sequences[] = {1u, 2u, 3u, 4u};

    setup_four_records(&flash, &storage);
    const vg_actuator_start_journal_flash_accepted_record_t retained = storage.records[0];
    // One copied record is program #1; the new header is program #2.
    vg_simulated_flash_backend_set_fault(&flash, VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM, 2u, 1u);
    assert(vg_actuator_start_journal_storage_compact(&storage, &retained, 1u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
    vg_simulated_flash_backend_clear_fault(&flash);
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    assert(recovered.authoritative_bank == 0u);
    assert_history_or_locked(&recovered, old_sequences, 4u);

    setup_four_records(&flash, &storage);
    const vg_actuator_start_journal_flash_accepted_record_t retained_again = storage.records[0];
    vg_simulated_flash_backend_set_fault(&flash, VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM, 2u, 1u);
    assert(vg_actuator_start_journal_storage_compact(&storage, &retained_again, 1u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
    vg_simulated_flash_backend_clear_fault(&flash);
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    assert(recovered.authoritative_bank == 1u);
    assert(recovered.current_high_water == 4u);
    assert(recovered.record_count == 1u && recovered.records[0].sequence == 1u);
}

static void test_compaction_fault_matrix_and_cleanup(void) {
    static const vg_simulated_flash_fault_t erase_faults[] = {
        VG_SIMULATED_FLASH_FAULT_BEFORE_ERASE,
        VG_SIMULATED_FLASH_FAULT_DURING_ERASE,
        VG_SIMULATED_FLASH_FAULT_AFTER_ERASE,
    };
    static const vg_simulated_flash_fault_t program_faults[] = {
        VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM,
        VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM,
        VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM,
    };
    uint64_t old_sequences[] = {1u, 2u, 3u, 4u};

    for (size_t fault = 0; fault < sizeof(erase_faults) / sizeof(erase_faults[0]); ++fault) {
        vg_simulated_flash_backend_t flash;
        vg_actuator_start_journal_storage_t storage;
        vg_actuator_start_journal_storage_t recovered;
        setup_four_records(&flash, &storage);
        const vg_actuator_start_journal_flash_accepted_record_t retained = storage.records[0];
        vg_simulated_flash_backend_set_fault(&flash, erase_faults[fault], 1u, 777u);
        assert(vg_actuator_start_journal_storage_compact(&storage, &retained, 1u) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
        vg_simulated_flash_backend_clear_fault(&flash);
        (void)reboot(&flash, &recovered);
        assert_history_or_locked(&recovered, old_sequences, 4u);
    }

    // Exercise each copied record (program occurrences 1..3), then the new
    // header (occurrence 4). Before header validity, old history always wins.
    for (size_t occurrence = 1u; occurrence <= 4u; ++occurrence) {
        for (size_t fault = 0; fault < sizeof(program_faults) / sizeof(program_faults[0]); ++fault) {
            vg_simulated_flash_backend_t flash;
            vg_actuator_start_journal_storage_t storage;
            vg_actuator_start_journal_storage_t recovered;
            setup_four_records(&flash, &storage);
            vg_actuator_start_journal_flash_accepted_record_t retained[3] = {
                storage.records[0], storage.records[1], storage.records[2],
            };
            vg_simulated_flash_backend_set_fault(&flash, program_faults[fault], occurrence, 37u);
            assert(vg_actuator_start_journal_storage_compact(&storage, retained, 3u) ==
                   VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
            vg_simulated_flash_backend_clear_fault(&flash);
            (void)reboot(&flash, &recovered);
            if (occurrence < 4u || program_faults[fault] != VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM) {
                assert_history_or_locked(&recovered, old_sequences, 4u);
            } else {
                assert(recovered.authoritative_bank == 1u);
                assert(recovered.current_high_water == 4u);
            }
        }
    }

    // Destination erase consumes occurrences 1..3. A cut in old-bank cleanup
    // occurs at occurrence 4 and cannot revoke the new header's authority.
    for (size_t fault = 0; fault < sizeof(erase_faults) / sizeof(erase_faults[0]); ++fault) {
        vg_simulated_flash_backend_t flash;
        vg_actuator_start_journal_storage_t storage;
        vg_actuator_start_journal_storage_t recovered;
        setup_four_records(&flash, &storage);
        const vg_actuator_start_journal_flash_accepted_record_t retained = storage.records[0];
        vg_simulated_flash_backend_set_fault(&flash, erase_faults[fault], 4u, 777u);
        assert(vg_actuator_start_journal_storage_compact(&storage, &retained, 1u) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED);
        vg_simulated_flash_backend_clear_fault(&flash);
        const vg_actuator_start_journal_storage_state_t state = reboot(&flash, &recovered);
        // AFTER_ERASE may have fully erased the only old-bank sector that
        // contained data; in that case cleanup has already completed.
        assert(state == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED ||
               state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
        assert(recovered.authoritative_bank == 1u);
        assert(recovered.current_high_water == 4u);
    }
}

static void test_cleanup_allows_append_but_blocks_rollover(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_actuator_start_journal_storage_t recovered;
    setup_four_records(&flash, &storage);
    const vg_actuator_start_journal_flash_accepted_record_t retained = storage.records[0];
    vg_simulated_flash_backend_set_fault(&flash, VG_SIMULATED_FLASH_FAULT_DURING_ERASE, 4u, 777u);
    assert(vg_actuator_start_journal_storage_compact(&storage, &retained, 1u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED);
    vg_simulated_flash_backend_clear_fault(&flash);
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    const vg_actuator_start_journal_record_t record = record_for(5u);
    uint64_t sequence = 0;
    assert(vg_actuator_start_journal_storage_append_verified(&recovered, &record, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(sequence == 5u);
    assert(reboot(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    assert(storage.authoritative_bank == 1u);
    assert(storage.current_high_water == 5u);
    assert(vg_actuator_start_journal_storage_compact(&storage, NULL, 0u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED);
    assert(vg_actuator_start_journal_storage_cleanup_inactive(&storage) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(storage.state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
}

static void test_compaction_trace_and_snapshot_validation(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    setup_four_records(&flash, &storage);
    vg_actuator_start_journal_flash_accepted_record_t fabricated = storage.records[0];
    fabricated.accepted_record.irrigation_line = 4u;
    assert(vg_actuator_start_journal_storage_compact(&storage, &fabricated, 1u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_RETAINED_SNAPSHOT);

    const vg_actuator_start_journal_flash_accepted_record_t retained = storage.records[0];
    flash.trace_count = 0u;
    assert(vg_actuator_start_journal_storage_compact(&storage, &retained, 1u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(flash.trace_count == 8u);
    for (size_t index = 0; index < 3u; ++index) {
        assert(flash.trace[index].operation == VG_SIMULATED_FLASH_TRACE_ERASE);
        assert(flash.trace[index].bank == 1u && flash.trace[index].index == index);
    }
    assert(flash.trace[3].operation == VG_SIMULATED_FLASH_TRACE_PROGRAM &&
           flash.trace[3].bank == 1u &&
           flash.trace[3].index == VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE);
    assert(flash.trace[4].operation == VG_SIMULATED_FLASH_TRACE_PROGRAM &&
           flash.trace[4].bank == 1u &&
           flash.trace[4].index == VG_ACTUATOR_START_JOURNAL_STORAGE_HEADER_PAGE);
    for (size_t index = 0; index < 3u; ++index) {
        assert(flash.trace[5u + index].operation == VG_SIMULATED_FLASH_TRACE_ERASE);
        assert(flash.trace[5u + index].bank == 0u && flash.trace[5u + index].index == index);
    }
}

static void test_full_journal_and_exhaustion(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_simulated_flash_backend_init(&flash);
    initialize(&flash, &storage);
    for (unsigned int number = 1u;
         number <= VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT; ++number) {
        const vg_actuator_start_journal_record_t record = record_for(number);
        uint64_t sequence = 0;
        assert(vg_actuator_start_journal_storage_append_verified(&storage, &record, &sequence) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
        assert(sequence == number);
    }
    const vg_actuator_start_journal_record_t extra = record_for(99u);
    uint64_t sequence = 0;
    assert(vg_actuator_start_journal_storage_append_verified(&storage, &extra, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_FULL);
    assert(vg_actuator_start_journal_storage_compact(&storage, storage.records, storage.record_count) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_FULL);
}

static void test_corruption_unsupported_gap_and_reserved_pages_lock(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_actuator_start_journal_storage_t recovered;
    setup_four_records(&flash, &storage);
    flash.bytes[0][VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE][0] ^= 1u;
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);

    setup_four_records(&flash, &storage);
    flash.bytes[0][VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RESERVED_PAGE][0] = 0u;
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);

    vg_simulated_flash_backend_init(&flash);
    initialize(&flash, &storage);
    const vg_actuator_start_journal_record_t record = record_for(1u);
    vg_actuator_start_journal_flash_accepted_record_t encoded_record = {
        .sequence = 1u,
        .accepted_record = record,
    };
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    assert(vg_actuator_start_journal_flash_encode_accepted_record(&encoded_record, page));
    const vg_actuator_start_journal_storage_backend_t backend = interface_for(&flash);
    assert(backend.program_page(backend.context, 0u,
                                VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE + 1u, page));
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);

    setup_four_records(&flash, &storage);
    flash.bytes[0][VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE][RECORD_LAYOUT_VERSION_OFFSET] = 2u;
    refresh_integrity(flash.bytes[0][VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE]);
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED);
}

static void test_unsupported_inactive_bank_preserves_authority(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_actuator_start_journal_storage_t recovered;
    vg_simulated_flash_backend_init(&flash);
    initialize(&flash, &storage);
    uint8_t header[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    const vg_actuator_start_journal_flash_bank_header_t value = {
        .generation = 2u,
        .sequence_high_water_mark = 0u,
        .record_page_size = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
        .logical_capacity = VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY,
    };
    assert(vg_actuator_start_journal_flash_encode_bank_header(&value, header));
    header[HEADER_LAYOUT_VERSION_OFFSET] = 3u;
    refresh_integrity(header);
    const vg_actuator_start_journal_storage_backend_t backend = interface_for(&flash);
    assert(backend.program_page(backend.context, 1u, 0u, header));
    assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    assert(recovered.authoritative_bank == 0u);
}

static void test_ambiguous_dual_headers_fail_closed(void) {
    static const uint64_t generations[] = {1u, 3u};
    for (size_t index = 0; index < sizeof(generations) / sizeof(generations[0]); ++index) {
        vg_simulated_flash_backend_t flash;
        vg_actuator_start_journal_storage_t storage;
        vg_actuator_start_journal_storage_t recovered;
        vg_simulated_flash_backend_init(&flash);
        initialize(&flash, &storage);
        const vg_actuator_start_journal_flash_bank_header_t header = {
            .generation = generations[index],
            .sequence_high_water_mark = 0u,
            .record_page_size = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
            .logical_capacity = VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY,
        };
        uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
        assert(vg_actuator_start_journal_flash_encode_bank_header(&header, page));
        const vg_actuator_start_journal_storage_backend_t backend = interface_for(&flash);
        assert(backend.program_page(backend.context, 1u, 0u, page));
        assert(reboot(&flash, &recovered) == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);
        assert(!vg_actuator_start_journal_storage_is_start_enabled(&recovered));
    }
}

int main(void) {
    test_simulated_nor_semantics();
    test_blank_initialization_and_reconstruction();
    test_initialization_power_cuts();
    test_append_power_cuts();
    test_duplicate_and_exhausted_boundaries();
    test_empty_and_partial_compaction_high_water();
    test_header_last_authority();
    test_compaction_fault_matrix_and_cleanup();
    test_cleanup_allows_append_but_blocks_rollover();
    test_compaction_trace_and_snapshot_validation();
    test_full_journal_and_exhaustion();
    test_corruption_unsupported_gap_and_reserved_pages_lock();
    test_unsupported_inactive_bank_preserves_authority();
    test_ambiguous_dual_headers_fail_closed();
    puts("actuator_start_journal_storage_tests: passed");
    return 0;
}
