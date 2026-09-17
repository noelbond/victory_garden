#include "combined_actuator_journal_runtime_state.h"

#include <string.h>

static void unhealthy(vg_combined_actuator_journal_runtime_state_t *runtime,
                      vg_combined_actuator_journal_health_t health) {
    memset(runtime, 0, sizeof(*runtime));
    runtime->health = health;
    runtime->authoritative_bank = VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT;
}

void vg_combined_actuator_journal_runtime_state_from_storage(
    vg_combined_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_storage_t *storage,
    bool backend_read_failed
) {
    if (!runtime) return;
    if (backend_read_failed || !storage) {
        unhealthy(runtime, VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE);
        return;
    }
    memset(runtime, 0, sizeof(*runtime));
    runtime->authoritative_bank = storage->authoritative_bank;
    runtime->record_count = storage->record_count;
    runtime->sequence_high_water = storage->current_high_water;
    switch (storage->state) {
        case VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK:
            runtime->health = VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_BLANK; break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY:
            runtime->health = VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY;
            runtime->durable_history_trustworthy = true; break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS:
            runtime->health = VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS;
            runtime->durable_history_trustworthy = true; break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED:
            runtime->health = VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED;
            runtime->durable_history_trustworthy = true;
            runtime->cleanup_required = true; break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED:
            unhealthy(runtime, VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_UNSUPPORTED); break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT:
        default:
            unhealthy(runtime, VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_CORRUPT); break;
    }
}

const char *vg_combined_actuator_journal_health_name(vg_combined_actuator_journal_health_t health) {
    static const char *const names[] = { "blank", "healthy_empty", "healthy_with_records",
        "cleanup_required", "corrupt", "unsupported", "backend_failure" };
    return health <= VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE ? names[health] : "unknown";
}
