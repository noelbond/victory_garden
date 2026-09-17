#pragma once

#include "dedicated_actuator_journal_maintenance.h"
#include "dedicated_actuator_journal_persistence.h"
#include "dedicated_actuator_journal_runtime_state.h"
#include "pico_actuator_journal_flash.h"

typedef bool (*vg_dedicated_actuator_any_output_active_fn)(void *context);

typedef struct {
    vg_pico_actuator_journal_flash_t physical_flash;
    vg_actuator_start_journal_storage_backend_t physical_backend;
    vg_actuator_start_journal_storage_t storage;
    // Static caller-owned snapshot used only by an on-demand full-journal
    // compaction. Keeping it here avoids a multi-kilobyte callback stack use.
    vg_actuator_start_journal_flash_accepted_record_t retained_snapshot[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    bool backend_read_failed;
    vg_dedicated_actuator_any_output_active_fn any_output_active;
    void *any_output_active_context;
    bool maintenance_policy_denied;
    vg_dedicated_actuator_journal_maintenance_result_t maintenance;
} vg_dedicated_actuator_journal_boot_t;

// Opens and reconstructs durable journal state through the physical backend.
// It performs no mutation.
void vg_dedicated_actuator_journal_boot_load(vg_dedicated_actuator_journal_boot_t *boot);

// Performs at most one boot maintenance action (blank initialization or
// inactive-bank cleanup) through the shared manager. Every physical mutation
// is guarded by the supplied authoritative output-active predicate.
void vg_dedicated_actuator_journal_boot_maintain(
    vg_dedicated_actuator_journal_boot_t *boot,
    vg_dedicated_actuator_any_output_active_fn any_output_active,
    void *any_output_active_context
);

// START-time durable append boundary. It applies the all-outputs-idle page
// program policy, delegates encode/program/readback verification to shared
// storage, and commits reconstructed RAM only after verified bytes exist.
vg_dedicated_actuator_journal_persistence_result_t
vg_dedicated_actuator_journal_boot_append_prepared_start(
    vg_dedicated_actuator_journal_boot_t *boot,
    const vg_actuator_start_journal_candidate_t *candidate,
    uint64_t *sequence_out
);

// Read-only preflight for START before it prepares a candidate.
vg_dedicated_actuator_journal_persistence_result_t
vg_dedicated_actuator_journal_boot_start_append_preflight(
    const vg_dedicated_actuator_journal_boot_t *boot
);

// Performs at most one on-demand reclamation attempt for an already
// classified full journal. It atomically fences the all-outputs-idle check
// and every shared storage mutation; the caller must reclassify and recheck
// freshness before attempting the ordinary append.
vg_dedicated_actuator_journal_reclaim_result_t
vg_dedicated_actuator_journal_boot_reclaim_full_start(
    vg_dedicated_actuator_journal_boot_t *boot,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time
);
