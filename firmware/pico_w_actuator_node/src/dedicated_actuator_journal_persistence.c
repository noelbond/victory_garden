#include "dedicated_actuator_journal_persistence.h"

#include "actuator_flash_mutation_policy.h"

static void map_runtime(
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    const bool *backend_read_failed
) {
    vg_dedicated_actuator_journal_runtime_state_from_storage(
        runtime,
        storage,
        backend_read_failed && *backend_read_failed
    );
}

static void reconstruct_after_commit_failure(
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    const bool *backend_read_failed
) {
    if (storage) {
        const vg_actuator_start_journal_storage_backend_t backend = storage->backend;
        (void)vg_actuator_start_journal_storage_open(storage, &backend);
    }
    map_runtime(storage, runtime, backend_read_failed);
}

vg_dedicated_actuator_journal_persistence_result_t
vg_dedicated_actuator_journal_persistence_preflight(
    const vg_dedicated_actuator_journal_runtime_state_t *runtime,
    bool any_output_active
) {
    if (!vg_dedicated_actuator_journal_health_allows_start(runtime)) {
        return VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE;
    }
    return vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM,
               any_output_active
           ) == VG_ACTUATOR_FLASH_MUTATION_ALLOWED
               ? VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_OK
               : VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_BUSY;
}

vg_dedicated_actuator_journal_persistence_result_t
vg_dedicated_actuator_journal_persistence_append_prepared(
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    bool *backend_read_failed,
    bool any_output_active,
    const vg_actuator_start_journal_candidate_t *candidate,
    uint64_t *sequence_out
) {
    if (!candidate || !candidate->prepared || !sequence_out) {
        return VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE;
    }
    const vg_dedicated_actuator_journal_persistence_result_t permission =
        vg_dedicated_actuator_journal_persistence_preflight(runtime, any_output_active);
    if (permission != VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_OK) {
        return permission;
    }

    const vg_actuator_start_journal_storage_result_t storage_result =
        vg_actuator_start_journal_storage_append_verified(
            storage,
            &candidate->record,
            sequence_out
        );
    map_runtime(storage, runtime, backend_read_failed);
    if (storage_result != VG_ACTUATOR_START_JOURNAL_STORAGE_OK) {
        return storage_result == VG_ACTUATOR_START_JOURNAL_STORAGE_FULL ||
                       storage_result == VG_ACTUATOR_START_JOURNAL_STORAGE_SEQUENCE_EXHAUSTED
                   ? VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_FULL
                   : VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE;
    }

    if (!vg_actuator_start_journal_commit_verified(&storage->logical_journal, candidate)) {
        // The physical record is now authoritative. Reconstruct instead of
        // rolling back so a replay will be recognized after this failure.
        reconstruct_after_commit_failure(storage, runtime, backend_read_failed);
        return VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_COMMIT_FAILED;
    }

    map_runtime(storage, runtime, backend_read_failed);
    return VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_OK;
}

static bool storage_has_append_room(const vg_actuator_start_journal_storage_t *storage,
                                    const vg_dedicated_actuator_journal_runtime_state_t *runtime) {
    return storage && vg_dedicated_actuator_journal_health_allows_start(runtime) &&
           storage->record_count < VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT;
}

static vg_dedicated_actuator_journal_reclaim_result_t map_reclaim_failure(
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    const bool *backend_read_failed
) {
    reconstruct_after_commit_failure(storage, runtime, backend_read_failed);
    return VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
}

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
) {
    if (!storage || !runtime || !retained_snapshot ||
        retained_snapshot_capacity < VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT ||
        !trusted_time || !vg_dedicated_actuator_journal_health_allows_start(runtime)) {
        return VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
    }
    if (vg_actuator_flash_mutation_policy_decide(
            VG_ACTUATOR_FLASH_MUTATION_JOURNAL_COMPACTION, any_output_active) !=
        VG_ACTUATOR_FLASH_MUTATION_ALLOWED) {
        return VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_BUSY;
    }

    // A previous header-last switch may have left obsolete bank cleanup
    // pending. Complete that first, then rebuild the snapshot from the
    // rescanned physical authority; never prune volatile logical history.
    if (runtime->cleanup_required) {
        if (vg_actuator_start_journal_storage_cleanup_inactive(storage) !=
            VG_ACTUATOR_START_JOURNAL_STORAGE_OK) {
            return map_reclaim_failure(storage, runtime, backend_read_failed);
        }
        map_runtime(storage, runtime, backend_read_failed);
        if (!vg_dedicated_actuator_journal_health_allows_start(runtime)) {
            return VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
        }
    }

    size_t retained_count = 0u;
    for (size_t index = 0u; index < storage->record_count; ++index) {
        const vg_actuator_start_journal_flash_accepted_record_t *record = &storage->records[index];
        if (!vg_actuator_start_journal_record_is_safe_to_prune(
                &record->accepted_record, trusted_now_epoch_seconds, trusted_time)) {
            retained_snapshot[retained_count++] = *record;
        }
    }
    if (retained_count == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT) {
        return VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_FULL;
    }

    const vg_actuator_start_journal_storage_result_t compact =
        vg_actuator_start_journal_storage_compact(storage, retained_snapshot, retained_count);
    // Compact itself rescans after every mutation outcome; explicitly reopen
    // here as the durable boundary before a later append can be considered.
    reconstruct_after_commit_failure(storage, runtime, backend_read_failed);
    if (compact != VG_ACTUATOR_START_JOURNAL_STORAGE_OK &&
        compact != VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED) {
        return VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
    }
    return storage_has_append_room(storage, runtime)
               ? VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_READY
               : VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_FULL;
}
