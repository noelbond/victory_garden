#pragma once

#include "combined_actuator_journal_maintenance.h"
#include "combined_actuator_journal_persistence.h"
#include "pico_actuator_journal_flash.h"

typedef bool (*vg_combined_actuator_any_output_active_fn)(void *context);

typedef struct {
    vg_pico_actuator_journal_flash_t physical_flash;
    vg_actuator_start_journal_storage_backend_t physical_backend;
    vg_actuator_start_journal_storage_t storage;
    vg_actuator_start_journal_flash_accepted_record_t retained_snapshot[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    vg_combined_actuator_journal_runtime_state_t runtime;
    bool backend_read_failed;
    vg_combined_actuator_any_output_active_fn any_output_active;
    void *any_output_active_context;
    bool maintenance_policy_denied;
    vg_combined_actuator_journal_maintenance_result_t maintenance;
} vg_combined_actuator_journal_boot_t;

void vg_combined_actuator_journal_boot_load(vg_combined_actuator_journal_boot_t *boot);
void vg_combined_actuator_journal_boot_maintain(
    vg_combined_actuator_journal_boot_t *boot,
    vg_combined_actuator_any_output_active_fn any_output_active,
    void *any_output_active_context
);
vg_combined_actuator_journal_persistence_result_t
vg_combined_actuator_journal_boot_append_prepared_start(
    vg_combined_actuator_journal_boot_t *boot,
    const vg_actuator_start_journal_candidate_t *candidate, uint64_t *sequence_out);
vg_combined_actuator_journal_reclaim_result_t vg_combined_actuator_journal_boot_reclaim_full_start(
    vg_combined_actuator_journal_boot_t *boot, int64_t trusted_now_epoch_seconds, bool trusted_time);
