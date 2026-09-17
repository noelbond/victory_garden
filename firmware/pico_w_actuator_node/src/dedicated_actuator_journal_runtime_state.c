#include "dedicated_actuator_journal_runtime_state.h"

#include <string.h>

static void set_unhealthy(
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    vg_dedicated_actuator_journal_health_t health
) {
    memset(runtime, 0, sizeof(*runtime));
    runtime->health = health;
    runtime->authoritative_bank = VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT;
}

void vg_dedicated_actuator_journal_runtime_state_from_storage(
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_storage_t *storage,
    bool backend_read_failed
) {
    if (!runtime) {
        return;
    }
    if (backend_read_failed || !storage) {
        set_unhealthy(runtime, VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE);
        return;
    }

    memset(runtime, 0, sizeof(*runtime));
    runtime->authoritative_bank = storage->authoritative_bank;
    runtime->record_count = storage->record_count;
    runtime->sequence_high_water = storage->current_high_water;

    switch (storage->state) {
        case VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK:
            runtime->health = VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BLANK;
            break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY:
            runtime->health = VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY;
            runtime->durable_history_trustworthy = true;
            break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS:
            runtime->health = VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS;
            runtime->durable_history_trustworthy = true;
            break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED:
            runtime->health = VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED;
            runtime->durable_history_trustworthy = true;
            runtime->cleanup_required = true;
            break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED:
            set_unhealthy(runtime, VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_UNSUPPORTED);
            break;
        case VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT:
        default:
            set_unhealthy(runtime, VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CORRUPT);
            break;
    }
}

const char *vg_dedicated_actuator_journal_health_name(
    vg_dedicated_actuator_journal_health_t health
) {
    switch (health) {
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BLANK:
            return "blank";
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY:
            return "healthy_empty";
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS:
            return "healthy_with_records";
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED:
            return "cleanup_required";
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CORRUPT:
            return "corrupt";
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_UNSUPPORTED:
            return "unsupported";
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE:
            return "backend_failure";
        default:
            return "unknown";
    }
}
