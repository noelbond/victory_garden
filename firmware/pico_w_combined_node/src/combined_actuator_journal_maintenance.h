#pragma once

#include "combined_actuator_journal_runtime_state.h"

typedef enum {
    VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_NONE = 0,
    VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK,
    VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE,
} vg_combined_actuator_journal_maintenance_action_t;

typedef struct {
    vg_combined_actuator_journal_maintenance_action_t action;
    bool mutation_attempted;
    vg_actuator_start_journal_storage_result_t storage_result;
    vg_actuator_start_journal_storage_state_t final_state;
} vg_combined_actuator_journal_maintenance_result_t;

vg_combined_actuator_journal_maintenance_action_t
vg_combined_actuator_journal_maintenance_action_for_health(vg_combined_actuator_journal_health_t health);
void vg_combined_actuator_journal_maintenance_run(
    vg_actuator_start_journal_storage_t *storage,
    vg_combined_actuator_journal_maintenance_result_t *result
);
