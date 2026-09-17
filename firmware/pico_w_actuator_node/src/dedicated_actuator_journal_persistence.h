#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "actuator_start_journal_storage.h"
#include "dedicated_actuator_journal_admission.h"

typedef enum {
    VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_OK = 0,
    VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_BUSY,
    VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_FULL,
    VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE,
    VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_COMMIT_FAILED,
} vg_dedicated_actuator_journal_persistence_result_t;

// Result of the one-shot, full-journal reclamation path. READY means the
// durable authority was rescanned and has room for the caller to retry its
// normal append; it does not itself accept the current START.
typedef enum {
    VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_READY = 0,
    VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_BUSY,
    VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_FULL,
    VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE,
} vg_dedicated_actuator_journal_reclaim_result_t;

// Applies the temporary Step 52 policy before constructing a candidate: a
// record page may be programmed only while every actuator output is idle.
vg_dedicated_actuator_journal_persistence_result_t
vg_dedicated_actuator_journal_persistence_preflight(
    const vg_dedicated_actuator_journal_runtime_state_t *runtime,
    bool any_output_active
);

// Programs and readback-verifies one prepared ACCEPTED record, then commits it
// to reconstructed RAM history. The storage manager owns all physical I/O;
// this boundary never initializes, erases, cleans, or compacts storage.
// `backend_read_failed` is adapter-owned sticky state and is updated by the
// caller's backend callbacks during append/reconstruction.
vg_dedicated_actuator_journal_persistence_result_t
vg_dedicated_actuator_journal_persistence_append_prepared(
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    bool *backend_read_failed,
    bool any_output_active,
    const vg_actuator_start_journal_candidate_t *candidate,
    uint64_t *sequence_out
);

// Reclaims a physically full durable history only for an unseen START that
// has already been read-only classified as FULL. It snapshots the accepted
// flash records that are not safely prunable, then uses the shared
// header-last compaction manager. The caller supplies static scratch storage;
// RAM history is never pruned in place before durable compaction succeeds.
vg_dedicated_actuator_journal_reclaim_result_t
vg_dedicated_actuator_journal_persistence_reclaim_full(
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    bool *backend_read_failed,
    bool any_output_active,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time,
    vg_actuator_start_journal_flash_accepted_record_t *retained_snapshot,
    size_t retained_snapshot_capacity
);
