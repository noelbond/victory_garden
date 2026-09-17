#include "combined_actuator_journal_admission.h"

bool vg_combined_actuator_journal_health_allows_start(
    const vg_combined_actuator_journal_runtime_state_t *runtime) {
    return runtime && runtime->durable_history_trustworthy &&
           (runtime->health == VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY ||
            runtime->health == VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS ||
            runtime->health == VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED);
}

vg_combined_actuator_journal_admission_t vg_combined_actuator_journal_classify_start(
    const vg_combined_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_t *journal,
    const char *idempotency_key, const char *zone_id, const char *node_id,
    uint8_t irrigation_line, int64_t issued_at_epoch_seconds) {
    if (!vg_combined_actuator_journal_health_allows_start(runtime))
        return VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_UNAVAILABLE;
    vg_actuator_start_journal_candidate_t candidate;
    switch (vg_actuator_start_journal_prepare(journal, idempotency_key, zone_id, node_id,
                                               irrigation_line, issued_at_epoch_seconds, &candidate)) {
        case VG_ACTUATOR_START_JOURNAL_NEW: return VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_NEW;
        case VG_ACTUATOR_START_JOURNAL_DUPLICATE: return VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE;
        case VG_ACTUATOR_START_JOURNAL_KEY_CONFLICT: return VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT;
        case VG_ACTUATOR_START_JOURNAL_FULL: return VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_FULL;
        default: return VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_UNAVAILABLE;
    }
}

vg_combined_actuator_active_start_result_t
vg_combined_actuator_journal_classify_active_start(
    const vg_combined_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_t *journal,
    bool identity_is_valid,
    const char *idempotency_key, const char *zone_id, const char *node_id,
    uint8_t irrigation_line, int64_t issued_at_epoch_seconds) {
    if (!identity_is_valid) {
        return VG_COMBINED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING;
    }

    switch (vg_combined_actuator_journal_classify_start(
        runtime, journal, idempotency_key, zone_id, node_id, irrigation_line,
        issued_at_epoch_seconds)) {
        case VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE:
            return VG_COMBINED_ACTUATOR_ACTIVE_START_DUPLICATE;
        case VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT:
            return VG_COMBINED_ACTUATOR_ACTIVE_START_KEY_CONFLICT;
        case VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_UNAVAILABLE:
        case VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_NEW:
        case VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_FULL:
        default:
            return VG_COMBINED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING;
    }
}
