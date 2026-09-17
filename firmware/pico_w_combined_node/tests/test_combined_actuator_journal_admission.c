#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "combined_actuator_journal_admission.h"

static vg_combined_actuator_journal_runtime_state_t healthy(size_t count) {
    return (vg_combined_actuator_journal_runtime_state_t){
        .health = count ? VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS
                        : VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY,
        .durable_history_trustworthy = true, .record_count = count };
}

static void test_identity_admission(void) {
    vg_actuator_start_journal_record_t records[VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY] = {0};
    vg_actuator_start_journal_t journal;
    assert(vg_actuator_start_journal_init(&journal, records, VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY));
    vg_combined_actuator_journal_runtime_state_t runtime = healthy(0u);
    assert(vg_combined_actuator_journal_classify_start(&runtime, &journal, "key", "zone", "node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_NEW);
    vg_actuator_start_journal_candidate_t candidate;
    assert(vg_actuator_start_journal_prepare(&journal, "key", "zone", "node", 1u, 10, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
    assert(vg_actuator_start_journal_commit_verified(&journal, &candidate));
    runtime = healthy(1u);
    assert(vg_combined_actuator_journal_classify_start(&runtime, &journal, "key", "zone", "node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);
    assert(vg_combined_actuator_journal_classify_start(&runtime, &journal, "key", "other-zone", "node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT);
    assert(vg_combined_actuator_journal_classify_start(&runtime, &journal, "key", "zone", "other-node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT);
    assert(vg_combined_actuator_journal_classify_start(&runtime, &journal, "key", "zone", "node", 2u, 10) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT);
    assert(vg_combined_actuator_journal_classify_start(&runtime, &journal, "key", "zone", "node", 1u, 11) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT);
}

static void test_untrusted_and_full(void) {
    vg_actuator_start_journal_record_t records[VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY] = {0};
    vg_actuator_start_journal_t journal;
    assert(vg_actuator_start_journal_init(&journal, records, VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY));
    vg_combined_actuator_journal_runtime_state_t bad = { .health = VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_CORRUPT };
    assert(vg_combined_actuator_journal_classify_start(&bad, &journal, "key", "zone", "node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_UNAVAILABLE);
    for (size_t i = 0; i < VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY; ++i) {
        vg_actuator_start_journal_candidate_t candidate;
        char key[16]; snprintf(key, sizeof(key), "key%u", (unsigned)i);
        assert(vg_actuator_start_journal_prepare(&journal, key, "zone", "node", 1u, 10 + (int)i, &candidate) ==
               VG_ACTUATOR_START_JOURNAL_NEW);
        assert(vg_actuator_start_journal_commit_verified(&journal, &candidate));
    }
    vg_combined_actuator_journal_runtime_state_t runtime = healthy(VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY);
    assert(vg_combined_actuator_journal_classify_start(&runtime, &journal, "new", "zone", "node", 1u, 99) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_FULL);
    assert(vg_combined_actuator_journal_classify_start(&runtime, &journal, "key0", "zone", "node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);
}

static void test_active_line_start_ordering_is_read_only(void) {
    vg_actuator_start_journal_record_t records[2] = {0};
    vg_actuator_start_journal_t journal;
    assert(vg_actuator_start_journal_init(&journal, records, 2u));
    vg_actuator_start_journal_candidate_t candidate;
    assert(vg_actuator_start_journal_prepare(&journal, "key", "zone", "node", 1u, 10, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
    assert(vg_actuator_start_journal_commit_verified(&journal, &candidate));
    const vg_combined_actuator_journal_runtime_state_t runtime = healthy(1u);
    vg_actuator_start_journal_record_t before[2];
    memcpy(before, records, sizeof(records));

    // This models the handler after routing has resolved a currently-running
    // line. The helper has only const journal inputs and no active-run input,
    // so none of these outcomes can alter the durable history or that run.
    assert(vg_combined_actuator_journal_classify_active_start(
               &runtime, &journal, true, "key", "zone", "node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_ACTIVE_START_DUPLICATE);
    assert(vg_combined_actuator_journal_classify_active_start(
               &runtime, &journal, true, "key", "zone", "other-node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_ACTIVE_START_KEY_CONFLICT);
    assert(vg_combined_actuator_journal_classify_active_start(
               &runtime, &journal, true, "key", "zone", "node", 1u, 11) ==
           VG_COMBINED_ACTUATOR_ACTIVE_START_KEY_CONFLICT);
    assert(vg_combined_actuator_journal_classify_active_start(
               &runtime, &journal, true, "other-key", "zone", "node", 1u, 11) ==
           VG_COMBINED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING);
    assert(vg_combined_actuator_journal_classify_active_start(
               &runtime, &journal, false, "key", "zone", "node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING);

    const vg_combined_actuator_journal_runtime_state_t corrupt = {
        .health = VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_CORRUPT,
        .durable_history_trustworthy = true,
    };
    assert(vg_combined_actuator_journal_classify_active_start(
               &corrupt, &journal, true, "key", "zone", "node", 1u, 10) ==
           VG_COMBINED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING);
    assert(memcmp(before, records, sizeof(records)) == 0);
}

int main(void) {
    test_identity_admission();
    test_untrusted_and_full();
    test_active_line_start_ordering_is_read_only();
    return 0;
}
