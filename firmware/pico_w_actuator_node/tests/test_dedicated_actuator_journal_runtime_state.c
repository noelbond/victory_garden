#include <assert.h>
#include <string.h>

#include "dedicated_actuator_journal_runtime_state.h"

static vg_actuator_start_journal_storage_t storage_with(
    vg_actuator_start_journal_storage_state_t state,
    size_t bank,
    size_t record_count,
    uint64_t high_water
) {
    vg_actuator_start_journal_storage_t storage;
    memset(&storage, 0, sizeof(storage));
    storage.state = state;
    storage.authoritative_bank = bank;
    storage.record_count = record_count;
    storage.current_high_water = high_water;
    return storage;
}

static void test_blank_is_known_empty_without_start_authority(void) {
    const vg_actuator_start_journal_storage_t storage = storage_with(
        VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK,
        VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT,
        0u,
        0u
    );
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &storage, false);
    assert(runtime.health == VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BLANK);
    assert(!runtime.durable_history_trustworthy);
    assert(!runtime.cleanup_required);
    assert(runtime.record_count == 0u);
    assert(runtime.sequence_high_water == 0u);
    assert(runtime.authoritative_bank == VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT);
}

static void test_healthy_history_and_cleanup_metadata_are_retained(void) {
    const vg_actuator_start_journal_storage_t empty = storage_with(
        VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY, 0u, 0u, 4u
    );
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &empty, false);
    assert(runtime.health == VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY);
    assert(runtime.durable_history_trustworthy);
    assert(!runtime.cleanup_required);
    assert(runtime.authoritative_bank == 0u);
    assert(runtime.record_count == 0u);
    assert(runtime.sequence_high_water == 4u);

    const vg_actuator_start_journal_storage_t healthy = storage_with(
        VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS, 1u, 3u, 12u
    );
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &healthy, false);
    assert(runtime.health == VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS);
    assert(runtime.durable_history_trustworthy);
    assert(!runtime.cleanup_required);
    assert(runtime.authoritative_bank == 1u);
    assert(runtime.record_count == 3u);
    assert(runtime.sequence_high_water == 12u);

    const vg_actuator_start_journal_storage_t cleanup = storage_with(
        VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED, 0u, 2u, 9u
    );
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &cleanup, false);
    assert(runtime.health == VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED);
    assert(runtime.durable_history_trustworthy);
    assert(runtime.cleanup_required);
    assert(runtime.authoritative_bank == 0u);
    assert(runtime.record_count == 2u);
    assert(runtime.sequence_high_water == 9u);
}

static void test_unhealthy_and_backend_failure_clear_authority(void) {
    const vg_actuator_start_journal_storage_t corrupt = storage_with(
        VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT, 0u, 2u, 4u
    );
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &corrupt, false);
    assert(runtime.health == VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CORRUPT);
    assert(!runtime.durable_history_trustworthy);
    assert(runtime.authoritative_bank == VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT);

    const vg_actuator_start_journal_storage_t unsupported = storage_with(
        VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED, 1u, 1u, 2u
    );
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &unsupported, false);
    assert(runtime.health == VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_UNSUPPORTED);
    assert(!runtime.durable_history_trustworthy);

    const vg_actuator_start_journal_storage_t healthy = storage_with(
        VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY, 0u, 0u, 7u
    );
    vg_dedicated_actuator_journal_runtime_state_from_storage(&runtime, &healthy, true);
    assert(runtime.health == VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE);
    assert(!runtime.durable_history_trustworthy);
    assert(runtime.authoritative_bank == VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT);
}

int main(void) {
    test_blank_is_known_empty_without_start_authority();
    test_healthy_history_and_cleanup_metadata_are_retained();
    test_unhealthy_and_backend_failure_clear_authority();
    return 0;
}
