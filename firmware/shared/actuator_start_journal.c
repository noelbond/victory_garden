#include "actuator_start_journal.h"

#include <limits.h>
#include <string.h>

static bool string_is_present_and_bounded(const char *value, size_t size) {
    if (!value || value[0] == '\0') {
        return false;
    }

    for (size_t i = 0; i < size; ++i) {
        if (value[i] == '\0') {
            return true;
        }
    }
    return false;
}

static bool record_matches(const vg_actuator_start_journal_record_t *record,
                           const char *idempotency_key,
                           const char *zone_id,
                           const char *node_id,
                           uint8_t irrigation_line,
                           int64_t issued_at_epoch_seconds) {
    return strcmp(record->idempotency_key, idempotency_key) == 0 &&
           strcmp(record->zone_id, zone_id) == 0 &&
           strcmp(record->node_id, node_id) == 0 &&
           record->irrigation_line == irrigation_line &&
           record->issued_at_epoch_seconds == issued_at_epoch_seconds;
}

static bool identity_is_valid(const char *idempotency_key, const char *zone_id,
                              const char *node_id, uint8_t irrigation_line) {
    return string_is_present_and_bounded(idempotency_key, VG_ACTUATOR_START_JOURNAL_MAX_IDEMPOTENCY_KEY_LEN) &&
           string_is_present_and_bounded(zone_id, VG_ACTUATOR_START_JOURNAL_MAX_ZONE_ID_LEN) &&
           string_is_present_and_bounded(node_id, VG_ACTUATOR_START_JOURNAL_MAX_NODE_ID_LEN) &&
           irrigation_line > 0;
}

bool vg_actuator_start_journal_init(vg_actuator_start_journal_t *journal,
                                    vg_actuator_start_journal_record_t *records,
                                    size_t capacity) {
    if (!journal || !records || capacity == 0) {
        return false;
    }

    journal->records = records;
    journal->capacity = capacity;
    return true;
}

bool vg_actuator_start_journal_record_is_valid(const vg_actuator_start_journal_record_t *record) {
    return record && record->accepted &&
           record->version == VG_ACTUATOR_START_JOURNAL_RECORD_VERSION &&
           identity_is_valid(record->idempotency_key, record->zone_id,
                             record->node_id, record->irrigation_line);
}

vg_actuator_start_journal_result_t vg_actuator_start_journal_prepare(
    const vg_actuator_start_journal_t *journal,
    const char *idempotency_key,
    const char *zone_id,
    const char *node_id,
    uint8_t irrigation_line,
    int64_t issued_at_epoch_seconds,
    vg_actuator_start_journal_candidate_t *candidate_out
) {
    if (!journal || !journal->records || journal->capacity == 0 || !candidate_out ||
        !identity_is_valid(idempotency_key, zone_id, node_id, irrigation_line)) {
        return VG_ACTUATOR_START_JOURNAL_INVALID_ARGUMENT;
    }

    memset(candidate_out, 0, sizeof(*candidate_out));
    size_t first_unused_slot = journal->capacity;

    for (size_t i = 0; i < journal->capacity; ++i) {
        const vg_actuator_start_journal_record_t *record = &journal->records[i];
        if (!record->accepted) {
            if (first_unused_slot == journal->capacity) {
                first_unused_slot = i;
            }
            continue;
        }

        if (!vg_actuator_start_journal_record_is_valid(record)) {
            return VG_ACTUATOR_START_JOURNAL_INVALID_RECORD;
        }

        if (strcmp(record->idempotency_key, idempotency_key) != 0) {
            continue;
        }

        return record_matches(record, idempotency_key, zone_id, node_id, irrigation_line,
                              issued_at_epoch_seconds)
            ? VG_ACTUATOR_START_JOURNAL_DUPLICATE
            : VG_ACTUATOR_START_JOURNAL_KEY_CONFLICT;
    }

    if (first_unused_slot == journal->capacity) {
        return VG_ACTUATOR_START_JOURNAL_FULL;
    }

    candidate_out->prepared = true;
    candidate_out->slot = first_unused_slot;
    candidate_out->record.accepted = true;
    candidate_out->record.version = VG_ACTUATOR_START_JOURNAL_RECORD_VERSION;
    memcpy(candidate_out->record.idempotency_key, idempotency_key, strlen(idempotency_key) + 1u);
    memcpy(candidate_out->record.zone_id, zone_id, strlen(zone_id) + 1u);
    memcpy(candidate_out->record.node_id, node_id, strlen(node_id) + 1u);
    candidate_out->record.irrigation_line = irrigation_line;
    candidate_out->record.issued_at_epoch_seconds = issued_at_epoch_seconds;
    return VG_ACTUATOR_START_JOURNAL_NEW;
}

bool vg_actuator_start_journal_commit_verified(
    vg_actuator_start_journal_t *journal,
    const vg_actuator_start_journal_candidate_t *candidate
) {
    if (!journal || !journal->records || journal->capacity == 0 || !candidate ||
        !candidate->prepared || candidate->slot >= journal->capacity ||
        !vg_actuator_start_journal_record_is_valid(&candidate->record)) {
        return false;
    }

    // A caller must not overwrite an accepted record after persistence. This
    // also protects against stale candidates in a future concurrent adapter.
    if (journal->records[candidate->slot].accepted) {
        return false;
    }

    for (size_t i = 0; i < journal->capacity; ++i) {
        const vg_actuator_start_journal_record_t *record = &journal->records[i];
        if (!record->accepted) {
            continue;
        }
        if (!vg_actuator_start_journal_record_is_valid(record) ||
            strcmp(record->idempotency_key, candidate->record.idempotency_key) == 0) {
            return false;
        }
    }

    journal->records[candidate->slot] = candidate->record;
    return true;
}

bool vg_actuator_start_journal_record_is_safe_to_prune(
    const vg_actuator_start_journal_record_t *record,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time
) {
    const int64_t retention_window = VG_ACTUATOR_COMMAND_MAX_START_AGE_SECONDS +
                                     VG_ACTUATOR_START_JOURNAL_RETENTION_MARGIN_SECONDS;
    if (!trusted_time || !vg_actuator_start_journal_record_is_valid(record) ||
        record->issued_at_epoch_seconds > INT64_MAX - retention_window) {
        return false;
    }

    return trusted_now_epoch_seconds > record->issued_at_epoch_seconds + retention_window;
}

size_t vg_actuator_start_journal_prune(
    vg_actuator_start_journal_t *journal,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time
) {
    if (!journal || !journal->records || journal->capacity == 0 || !trusted_time) {
        return 0;
    }

    size_t removed = 0;
    for (size_t i = 0; i < journal->capacity; ++i) {
        vg_actuator_start_journal_record_t *record = &journal->records[i];
        if (record->accepted &&
            vg_actuator_start_journal_record_is_safe_to_prune(record,
                                                                trusted_now_epoch_seconds,
                                                                trusted_time)) {
            memset(record, 0, sizeof(*record));
            ++removed;
        }
    }
    return removed;
}
