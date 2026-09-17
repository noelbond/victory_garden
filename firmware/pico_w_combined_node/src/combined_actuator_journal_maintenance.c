#include "combined_actuator_journal_maintenance.h"

#include <string.h>

vg_combined_actuator_journal_maintenance_action_t
vg_combined_actuator_journal_maintenance_action_for_health(vg_combined_actuator_journal_health_t health) {
    return health == VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_BLANK
               ? VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK
               : health == VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED
                     ? VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE
                     : VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_NONE;
}

void vg_combined_actuator_journal_maintenance_run(
    vg_actuator_start_journal_storage_t *storage,
    vg_combined_actuator_journal_maintenance_result_t *result
) {
    if (!result) return;
    memset(result, 0, sizeof(*result));
    result->storage_result = VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_READY;
    result->final_state = storage ? storage->state : VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT;
    if (!storage) return;
    if (storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK) {
        result->action = VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK;
        result->mutation_attempted = true;
        result->storage_result = vg_actuator_start_journal_storage_initialize(storage);
    } else if (storage->state == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED) {
        result->action = VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE;
        result->mutation_attempted = true;
        result->storage_result = vg_actuator_start_journal_storage_cleanup_inactive(storage);
    } else {
        result->storage_result = VG_ACTUATOR_START_JOURNAL_STORAGE_OK;
        return;
    }
    const vg_actuator_start_journal_storage_backend_t backend = storage->backend;
    result->final_state = vg_actuator_start_journal_storage_open(storage, &backend);
}
