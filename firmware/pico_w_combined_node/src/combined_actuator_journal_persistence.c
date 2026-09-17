#include "combined_actuator_journal_persistence.h"

#include "actuator_flash_mutation_policy.h"

static void map(vg_actuator_start_journal_storage_t *storage,
                vg_combined_actuator_journal_runtime_state_t *runtime,
                const bool *read_failed) {
    vg_combined_actuator_journal_runtime_state_from_storage(
        runtime, storage, read_failed && *read_failed);
}
static void recover(vg_actuator_start_journal_storage_t *storage,
                    vg_combined_actuator_journal_runtime_state_t *runtime,
                    const bool *read_failed) {
    const vg_actuator_start_journal_storage_backend_t backend = storage->backend;
    (void)vg_actuator_start_journal_storage_open(storage, &backend);
    map(storage, runtime, read_failed);
}
vg_combined_actuator_journal_persistence_result_t
vg_combined_actuator_journal_persistence_append_prepared(
    vg_actuator_start_journal_storage_t *storage,
    vg_combined_actuator_journal_runtime_state_t *runtime,
    bool *backend_read_failed, bool any_output_active,
    const vg_actuator_start_journal_candidate_t *candidate, uint64_t *sequence_out) {
    if (!storage || !candidate || !candidate->prepared || !sequence_out ||
        !vg_combined_actuator_journal_health_allows_start(runtime))
        return VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE;
    if (vg_actuator_flash_mutation_policy_decide(
            VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM, any_output_active) !=
        VG_ACTUATOR_FLASH_MUTATION_ALLOWED)
        return VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_BUSY;
    const vg_actuator_start_journal_storage_result_t result =
        vg_actuator_start_journal_storage_append_verified(storage, &candidate->record, sequence_out);
    map(storage, runtime, backend_read_failed);
    if (result != VG_ACTUATOR_START_JOURNAL_STORAGE_OK)
        return result == VG_ACTUATOR_START_JOURNAL_STORAGE_FULL ||
                       result == VG_ACTUATOR_START_JOURNAL_STORAGE_SEQUENCE_EXHAUSTED
                   ? VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_FULL
                   : VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE;
    if (!vg_actuator_start_journal_commit_verified(&storage->logical_journal, candidate)) {
        recover(storage, runtime, backend_read_failed);
        return VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_COMMIT_FAILED;
    }
    map(storage, runtime, backend_read_failed);
    return VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_OK;
}

vg_combined_actuator_journal_reclaim_result_t
vg_combined_actuator_journal_persistence_reclaim_full(
    vg_actuator_start_journal_storage_t *storage,
    vg_combined_actuator_journal_runtime_state_t *runtime, bool *backend_read_failed,
    bool any_output_active, int64_t now, bool trusted_time,
    vg_actuator_start_journal_flash_accepted_record_t *snapshot, size_t snapshot_capacity) {
    if (!storage || !runtime || !snapshot ||
        snapshot_capacity < VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT || !trusted_time ||
        !vg_combined_actuator_journal_health_allows_start(runtime))
        return VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
    if (vg_actuator_flash_mutation_policy_decide(VG_ACTUATOR_FLASH_MUTATION_JOURNAL_COMPACTION,
                                                  any_output_active) != VG_ACTUATOR_FLASH_MUTATION_ALLOWED)
        return VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_BUSY;
    if (runtime->cleanup_required) {
        if (vg_actuator_start_journal_storage_cleanup_inactive(storage) != VG_ACTUATOR_START_JOURNAL_STORAGE_OK) {
            recover(storage, runtime, backend_read_failed);
            return VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
        }
        map(storage, runtime, backend_read_failed);
        if (!vg_combined_actuator_journal_health_allows_start(runtime))
            return VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
    }
    size_t count = 0u;
    for (size_t i = 0u; i < storage->record_count; ++i)
        if (!vg_actuator_start_journal_record_is_safe_to_prune(
                &storage->records[i].accepted_record, now, trusted_time)) snapshot[count++] = storage->records[i];
    if (count == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT)
        return VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_FULL;
    const vg_actuator_start_journal_storage_result_t result =
        vg_actuator_start_journal_storage_compact(storage, snapshot, count);
    recover(storage, runtime, backend_read_failed);
    if (result != VG_ACTUATOR_START_JOURNAL_STORAGE_OK &&
        result != VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED)
        return VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
    return vg_combined_actuator_journal_health_allows_start(runtime) &&
                   storage->record_count < VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT
               ? VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_READY
               : VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_FULL;
}
