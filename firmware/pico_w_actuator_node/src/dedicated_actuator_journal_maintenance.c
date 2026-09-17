#include "dedicated_actuator_journal_maintenance.h"

#include <string.h>

static vg_actuator_start_journal_storage_state_t rescan(
    vg_actuator_start_journal_storage_t *storage
) {
    const vg_actuator_start_journal_storage_backend_t backend = storage->backend;
    return vg_actuator_start_journal_storage_open(storage, &backend);
}

vg_dedicated_actuator_journal_maintenance_action_t
vg_dedicated_actuator_journal_maintenance_action_for_health(
    vg_dedicated_actuator_journal_health_t health
) {
    switch (health) {
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BLANK:
            return VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK;
        case VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED:
            return VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE;
        default:
            return VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE;
    }
}

void vg_dedicated_actuator_journal_maintenance_run(
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_maintenance_result_t *result
) {
    if (!result) {
        return;
    }
    memset(result, 0, sizeof(*result));
    result->action = VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE;
    result->storage_result = VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_READY;
    result->final_state = storage ? storage->state : VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT;
    if (!storage) {
        return;
    }

    if (storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK) {
        result->action = VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK;
        result->mutation_attempted = true;
        result->storage_result = vg_actuator_start_journal_storage_initialize(storage);
    } else if (storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED) {
        result->action = VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE;
        result->mutation_attempted = true;
        result->storage_result = vg_actuator_start_journal_storage_cleanup_inactive(storage);
    } else {
        result->storage_result = VG_ACTUATOR_START_JOURNAL_STORAGE_OK;
        return;
    }

    // The shared operation has its own recovery scan, but derive the final
    // target state from durable bytes again rather than trusting its result.
    result->final_state = rescan(storage);
}
