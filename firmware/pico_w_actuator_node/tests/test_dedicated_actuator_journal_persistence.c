#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "dedicated_actuator_journal_persistence.h"
#include "simulated_flash_backend.h"

static vg_actuator_start_journal_record_t record_for(unsigned int number) {
    vg_actuator_start_journal_record_t record;
    memset(&record, 0, sizeof(record));
    record.accepted = true;
    record.version = VG_ACTUATOR_START_JOURNAL_RECORD_VERSION;
    record.irrigation_line = (uint8_t)((number % 4u) + 1u);
    record.issued_at_epoch_seconds = 1700000000 + (int64_t)number;
    assert(snprintf(record.idempotency_key, sizeof(record.idempotency_key), "key-%u", number) > 0);
    assert(snprintf(record.zone_id, sizeof(record.zone_id), "zone-%u", number) > 0);
    assert(snprintf(record.node_id, sizeof(record.node_id), "node-%u", number) > 0);
    return record;
}

static void initialize(
    vg_simulated_flash_backend_t *flash,
    vg_actuator_start_journal_storage_t *storage,
    vg_dedicated_actuator_journal_runtime_state_t *runtime
) {
    vg_simulated_flash_backend_init(flash);
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(flash);
    assert(vg_actuator_start_journal_storage_open(storage, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
    assert(vg_actuator_start_journal_storage_initialize(storage) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    vg_dedicated_actuator_journal_runtime_state_from_storage(runtime, storage, false);
}

static vg_actuator_start_journal_candidate_t prepare(
    const vg_actuator_start_journal_storage_t *storage,
    const vg_actuator_start_journal_record_t *record
) {
    vg_actuator_start_journal_candidate_t candidate;
    assert(vg_actuator_start_journal_prepare(
               &storage->logical_journal,
               record->idempotency_key,
               record->zone_id,
               record->node_id,
               record->irrigation_line,
               record->issued_at_epoch_seconds,
               &candidate
           ) == VG_ACTUATOR_START_JOURNAL_NEW);
    return candidate;
}

static void test_idle_append_commits_and_survives_reboot(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    const vg_actuator_start_journal_record_t record = record_for(1u);
    const vg_actuator_start_journal_candidate_t candidate = prepare(&storage, &record);
    bool backend_read_failed = false;
    uint64_t sequence = 0u;
    flash.trace_count = 0u;

    assert(vg_dedicated_actuator_journal_persistence_preflight(&runtime, false) ==
           VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_OK);
    assert(vg_dedicated_actuator_journal_persistence_append_prepared(
               &storage, &runtime, &backend_read_failed, false, &candidate, &sequence
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_OK);
    assert(sequence == 1u);
    assert(flash.trace_count == 1u);
    assert(flash.trace[0].operation == VG_SIMULATED_FLASH_TRACE_PROGRAM);
    assert(runtime.health == VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS);
    assert(runtime.record_count == 1u);
    assert(runtime.sequence_high_water == 1u);
    assert(vg_actuator_start_journal_prepare(
               &storage.logical_journal, record.idempotency_key, record.zone_id,
               record.node_id, record.irrigation_line, record.issued_at_epoch_seconds,
               &(vg_actuator_start_journal_candidate_t){0}
           ) == VG_ACTUATOR_START_JOURNAL_DUPLICATE);

    vg_actuator_start_journal_storage_t rebooted;
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(&flash);
    assert(vg_actuator_start_journal_storage_open(&rebooted, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    assert(vg_actuator_start_journal_prepare(
               &rebooted.logical_journal, record.idempotency_key, record.zone_id,
               record.node_id, record.irrigation_line, record.issued_at_epoch_seconds,
               &(vg_actuator_start_journal_candidate_t){0}
           ) == VG_ACTUATOR_START_JOURNAL_DUPLICATE);
}

static void test_active_output_blocks_without_mutation(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    const vg_actuator_start_journal_record_t record = record_for(2u);
    const vg_actuator_start_journal_candidate_t candidate = prepare(&storage, &record);
    bool backend_read_failed = false;
    uint64_t sequence = 0u;
    flash.trace_count = 0u;

    assert(vg_dedicated_actuator_journal_persistence_append_prepared(
               &storage, &runtime, &backend_read_failed, true, &candidate, &sequence
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_BUSY);
    assert(flash.trace_count == 0u);
    assert(storage.record_count == 0u);
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &storage.logical_journal, record.idempotency_key,
               record.zone_id, record.node_id, record.irrigation_line,
               record.issued_at_epoch_seconds
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_NEW);
}

static void test_append_failure_never_commits_ram_history(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    const vg_actuator_start_journal_record_t record = record_for(3u);
    const vg_actuator_start_journal_candidate_t candidate = prepare(&storage, &record);
    bool backend_read_failed = false;
    uint64_t sequence = 0u;
    vg_simulated_flash_backend_set_fault(
        &flash, VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM, 1u, 0u
    );
    assert(vg_dedicated_actuator_journal_persistence_append_prepared(
               &storage, &runtime, &backend_read_failed, false, &candidate, &sequence
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE);
    assert(storage.record_count == 0u);
    assert(vg_actuator_start_journal_prepare(
               &storage.logical_journal, record.idempotency_key, record.zone_id,
               record.node_id, record.irrigation_line, record.issued_at_epoch_seconds,
               &(vg_actuator_start_journal_candidate_t){0}
           ) == VG_ACTUATOR_START_JOURNAL_NEW);
}

static void test_after_program_failure_preserves_a_durable_duplicate(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    const vg_actuator_start_journal_record_t record = record_for(8u);
    const vg_actuator_start_journal_candidate_t candidate = prepare(&storage, &record);
    bool backend_read_failed = false;
    uint64_t sequence = 0u;
    vg_simulated_flash_backend_set_fault(
        &flash, VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM, 1u, 0u
    );
    assert(vg_dedicated_actuator_journal_persistence_append_prepared(
               &storage, &runtime, &backend_read_failed, false, &candidate, &sequence
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE);
    vg_simulated_flash_backend_clear_fault(&flash);
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(&flash);
    assert(vg_actuator_start_journal_storage_open(&storage, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &storage, false);
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &storage.logical_journal, record.idempotency_key,
               record.zone_id, record.node_id, record.irrigation_line,
               record.issued_at_epoch_seconds
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);
}

static void test_full_journal_rejects_without_another_program(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    for (unsigned int number = 1u;
         number <= VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT;
         ++number) {
        const vg_actuator_start_journal_record_t record = record_for(number);
        uint64_t sequence = 0u;
        assert(vg_actuator_start_journal_storage_append_verified(&storage, &record, &sequence) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    }
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(&flash);
    assert(vg_actuator_start_journal_storage_open(&storage, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &storage, false);
    const vg_actuator_start_journal_record_t extra = record_for(99u);
    flash.trace_count = 0u;
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &storage.logical_journal, extra.idempotency_key,
               extra.zone_id, extra.node_id, extra.irrigation_line,
               extra.issued_at_epoch_seconds
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_FULL);
    assert(flash.trace_count == 0u);
}

static void fill_full(vg_actuator_start_journal_storage_t *storage) {
    for (unsigned int number = 1u;
         number <= VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT;
         ++number) {
        const vg_actuator_start_journal_record_t record = record_for(number);
        uint64_t sequence = 0u;
        assert(vg_actuator_start_journal_storage_append_verified(storage, &record, &sequence) ==
               VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
        assert(sequence == number);
    }
}

static void test_full_reclaim_prunes_only_expired_physical_snapshot(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    fill_full(&storage);
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(&flash);
    assert(vg_actuator_start_journal_storage_open(&storage, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &storage, false);
    vg_actuator_start_journal_flash_accepted_record_t snapshot[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    bool backend_read_failed = false;
    flash.trace_count = 0u;

    assert(vg_dedicated_actuator_journal_persistence_reclaim_full(
               &storage, &runtime, &backend_read_failed, false,
               1700000100, true, snapshot,
               VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_READY);
    assert(storage.record_count == 0u);
    assert(storage.current_high_water == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT);
    assert(runtime.record_count == 0u);
    assert(flash.trace_count > 0u);

    const vg_actuator_start_journal_record_t next = record_for(99u);
    const vg_actuator_start_journal_candidate_t candidate = prepare(&storage, &next);
    uint64_t sequence = 0u;
    assert(vg_dedicated_actuator_journal_persistence_append_prepared(
               &storage, &runtime, &backend_read_failed, false, &candidate, &sequence
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_OK);
    assert(sequence == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT + 1u);
}

static void test_full_reclaim_keeps_strict_retention_boundary(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    fill_full(&storage);
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(&flash);
    assert(vg_actuator_start_journal_storage_open(&storage, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &storage, false);
    vg_actuator_start_journal_flash_accepted_record_t snapshot[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    bool backend_read_failed = false;

    // key-32 is exactly issued_at + (20s max age + 10s margin), so the
    // shared strict 'now > boundary' rule retains it.
    assert(vg_dedicated_actuator_journal_persistence_reclaim_full(
               &storage, &runtime, &backend_read_failed, false,
               1700000062, true, snapshot,
               VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_READY);
    assert(storage.record_count == 1u);
    assert(strcmp(storage.records[0].accepted_record.idempotency_key, "key-32") == 0);
    assert(storage.records[0].sequence == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT);
    assert(storage.current_high_water == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT);
}

static void test_full_reclaim_needs_time_and_idle_outputs(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    fill_full(&storage);
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(&flash);
    assert(vg_actuator_start_journal_storage_open(&storage, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &storage, false);
    vg_actuator_start_journal_flash_accepted_record_t snapshot[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    bool backend_read_failed = false;
    flash.trace_count = 0u;

    assert(vg_dedicated_actuator_journal_persistence_reclaim_full(
               &storage, &runtime, &backend_read_failed, false,
               1700000100, false, snapshot,
               VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE);
    assert(flash.trace_count == 0u);
    assert(vg_dedicated_actuator_journal_persistence_reclaim_full(
               &storage, &runtime, &backend_read_failed, true,
               1700000100, true, snapshot,
               VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_BUSY);
    assert(flash.trace_count == 0u);
}

static void test_full_reclaim_leaves_all_retained_history_untouched(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    fill_full(&storage);
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(&flash);
    assert(vg_actuator_start_journal_storage_open(&storage, &backend) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &storage, false);
    vg_actuator_start_journal_flash_accepted_record_t snapshot[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    bool backend_read_failed = false;
    flash.trace_count = 0u;

    assert(vg_dedicated_actuator_journal_persistence_reclaim_full(
               &storage, &runtime, &backend_read_failed, false,
               1700000000, true, snapshot,
               VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_FULL);
    assert(storage.record_count == VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT);
    assert(flash.trace_count == 0u);
}

static void test_reclaim_cleans_pending_old_bank_before_compacting(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    fill_full(&storage);
    // The fourth erase is old-bank cleanup after header-last activation.
    // Failing it leaves the new history authoritative but cleanup-required.
    vg_simulated_flash_backend_set_fault(
        &flash, VG_SIMULATED_FLASH_FAULT_BEFORE_ERASE, 4u, 0u
    );
    assert(vg_actuator_start_journal_storage_compact(&storage, NULL, 0u) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED);
    vg_simulated_flash_backend_clear_fault(&flash);
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &storage, false);
    assert(runtime.cleanup_required);
    vg_actuator_start_journal_flash_accepted_record_t snapshot[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    bool backend_read_failed = false;

    assert(vg_dedicated_actuator_journal_persistence_reclaim_full(
               &storage, &runtime, &backend_read_failed, false,
               1700000100, true, snapshot,
               VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_READY);
    assert(!runtime.cleanup_required);
    assert(storage.state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
}

static void test_commit_failure_reconstructs_durable_duplicate(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    initialize(&flash, &storage, &runtime);
    const vg_actuator_start_journal_record_t record = record_for(4u);
    vg_actuator_start_journal_candidate_t candidate = prepare(&storage, &record);
    // Force only the caller-owned RAM commit to fail after a valid physical
    // append; reconstruction must preserve the newly durable identity.
    candidate.slot = VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT;
    bool backend_read_failed = false;
    uint64_t sequence = 0u;
    assert(vg_dedicated_actuator_journal_persistence_append_prepared(
               &storage, &runtime, &backend_read_failed, false, &candidate, &sequence
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_COMMIT_FAILED);
    assert(sequence == 1u);
    assert(runtime.record_count == 1u);
    assert(vg_actuator_start_journal_prepare(
               &storage.logical_journal, record.idempotency_key, record.zone_id,
               record.node_id, record.irrigation_line, record.issued_at_epoch_seconds,
               &(vg_actuator_start_journal_candidate_t){0}
           ) == VG_ACTUATOR_START_JOURNAL_DUPLICATE);
}

int main(void) {
    test_idle_append_commits_and_survives_reboot();
    test_active_output_blocks_without_mutation();
    test_append_failure_never_commits_ram_history();
    test_after_program_failure_preserves_a_durable_duplicate();
    test_commit_failure_reconstructs_durable_duplicate();
    test_full_journal_rejects_without_another_program();
    test_full_reclaim_prunes_only_expired_physical_snapshot();
    test_full_reclaim_keeps_strict_retention_boundary();
    test_full_reclaim_needs_time_and_idle_outputs();
    test_full_reclaim_leaves_all_retained_history_untouched();
    test_reclaim_cleans_pending_old_bank_before_compacting();
    return 0;
}
