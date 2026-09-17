#pragma once

#include "actuator_start_journal_storage.h"
#include "dedicated_actuator_journal_runtime_state.h"

typedef enum {
    VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE = 0,
    VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK,
    VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE,
} vg_dedicated_actuator_journal_maintenance_action_t;

typedef struct {
    vg_dedicated_actuator_journal_maintenance_action_t action;
    bool mutation_attempted;
    vg_actuator_start_journal_storage_result_t storage_result;
    vg_actuator_start_journal_storage_state_t final_state;
} vg_dedicated_actuator_journal_maintenance_result_t;

vg_dedicated_actuator_journal_maintenance_action_t
vg_dedicated_actuator_journal_maintenance_action_for_health(
    vg_dedicated_actuator_journal_health_t health
);

// Performs at most one shared-manager maintenance action, then rescans the
// physical backend. The supplied storage backend must authorize every actual
// program/erase operation; this controller makes no policy decision itself.
void vg_dedicated_actuator_journal_maintenance_run(
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_maintenance_result_t *result
);
