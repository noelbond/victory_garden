#pragma once

#include "combined_actuator_journal_admission.h"

typedef enum {
    VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_OK = 0,
    VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_BUSY,
    VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_FULL,
    VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE,
    VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_COMMIT_FAILED,
} vg_combined_actuator_journal_persistence_result_t;
typedef enum {
    VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_READY = 0,
    VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_BUSY,
    VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_FULL,
    VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE,
} vg_combined_actuator_journal_reclaim_result_t;

vg_combined_actuator_journal_persistence_result_t
vg_combined_actuator_journal_persistence_append_prepared(
    vg_actuator_start_journal_storage_t *storage,
    vg_combined_actuator_journal_runtime_state_t *runtime,
    bool *backend_read_failed, bool any_output_active,
    const vg_actuator_start_journal_candidate_t *candidate, uint64_t *sequence_out);
vg_combined_actuator_journal_reclaim_result_t
vg_combined_actuator_journal_persistence_reclaim_full(
    vg_actuator_start_journal_storage_t *storage,
    vg_combined_actuator_journal_runtime_state_t *runtime, bool *backend_read_failed,
    bool any_output_active, int64_t trusted_now_epoch_seconds, bool trusted_time,
    vg_actuator_start_journal_flash_accepted_record_t *snapshot, size_t snapshot_capacity);
