#include <assert.h>
#include <string.h>

#include "dedicated_actuator_journal_admission.h"

static vg_dedicated_actuator_journal_runtime_state_t trusted_runtime(
    vg_dedicated_actuator_journal_health_t health
) {
    vg_dedicated_actuator_journal_runtime_state_t runtime;
    memset(&runtime, 0, sizeof(runtime));
    runtime.health = health;
    runtime.durable_history_trustworthy = true;
    return runtime;
}

static void accept_start(vg_actuator_start_journal_t *journal,
                         const char *key, const char *zone, const char *node,
                         uint8_t line, int64_t issued_at) {
    vg_actuator_start_journal_candidate_t candidate;
    assert(vg_actuator_start_journal_prepare(
               journal, key, zone, node, line, issued_at, &candidate
           ) == VG_ACTUATOR_START_JOURNAL_NEW);
    assert(vg_actuator_start_journal_commit_verified(journal, &candidate));
}

static void test_only_initialized_healthy_states_allow_start(void) {
    const vg_dedicated_actuator_journal_health_t trusted[] = {
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY,
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS,
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED,
    };
    for (size_t index = 0; index < sizeof(trusted) / sizeof(trusted[0]); ++index) {
        const vg_dedicated_actuator_journal_runtime_state_t runtime = trusted_runtime(trusted[index]);
        assert(vg_dedicated_actuator_journal_health_allows_start(&runtime));
    }

    const vg_dedicated_actuator_journal_health_t untrusted[] = {
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BLANK,
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CORRUPT,
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_UNSUPPORTED,
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE,
    };
    for (size_t index = 0; index < sizeof(untrusted) / sizeof(untrusted[0]); ++index) {
        const vg_dedicated_actuator_journal_runtime_state_t runtime = trusted_runtime(untrusted[index]);
        assert(!vg_dedicated_actuator_journal_health_allows_start(&runtime));
    }
}

static void test_duplicate_conflicts_and_lookup_are_read_only(void) {
    vg_actuator_start_journal_record_t records[2];
    memset(records, 0, sizeof(records));
    vg_actuator_start_journal_t journal;
    assert(vg_actuator_start_journal_init(&journal, records, 2u));
    accept_start(&journal, "start-1", "zone1", "node1", 1u, 1700000000);
    const vg_dedicated_actuator_journal_runtime_state_t runtime = trusted_runtime(
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS
    );
    vg_actuator_start_journal_record_t before[2];
    memcpy(before, records, sizeof(records));

    // No trusted clock or freshness input is needed to identify a durable
    // duplicate; this represents both a duplicate received before SNTP and
    // the same duplicate received after it has become stale.
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &journal, "start-1", "zone1", "node1", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &journal, "start-1", "zone1", "node1", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &journal, "start-1", "other-zone", "node1", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT);
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &journal, "start-1", "zone1", "other-node", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT);
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &journal, "start-1", "zone1", "node1", 2u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT);
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &journal, "start-1", "zone1", "node1", 1u, 1700000001
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT);
    assert(vg_dedicated_actuator_journal_classify_start(
               &runtime, &journal, "start-2", "zone1", "node1", 1u, 1700000001
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_NEW);
    assert(memcmp(before, records, sizeof(records)) == 0);
}

static void test_full_and_unavailable_are_not_new_or_duplicates(void) {
    vg_actuator_start_journal_record_t records[1];
    memset(records, 0, sizeof(records));
    vg_actuator_start_journal_t journal;
    assert(vg_actuator_start_journal_init(&journal, records, 1u));
    accept_start(&journal, "start-1", "zone1", "node1", 1u, 1700000000);
    const vg_dedicated_actuator_journal_runtime_state_t healthy = trusted_runtime(
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS
    );
    assert(vg_dedicated_actuator_journal_classify_start(
               &healthy, &journal, "start-2", "zone1", "node1", 1u, 1700000001
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_FULL);

    const vg_dedicated_actuator_journal_runtime_state_t corrupt = trusted_runtime(
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CORRUPT
    );
    assert(vg_dedicated_actuator_journal_classify_start(
               &corrupt, &journal, "start-1", "zone1", "node1", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_UNAVAILABLE);
}

static void test_active_line_start_ordering_is_read_only(void) {
    vg_actuator_start_journal_record_t records[2];
    memset(records, 0, sizeof(records));
    vg_actuator_start_journal_t journal;
    assert(vg_actuator_start_journal_init(&journal, records, 2u));
    accept_start(&journal, "start-1", "zone1", "node1", 1u, 1700000000);
    const vg_dedicated_actuator_journal_runtime_state_t runtime = trusted_runtime(
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS
    );
    vg_actuator_start_journal_record_t before[2];
    memcpy(before, records, sizeof(records));

    // This models the handler after routing has resolved a currently-running
    // line. The helper has only const journal inputs and no active-run input,
    // so none of these outcomes can alter the durable history or that run.
    assert(vg_dedicated_actuator_journal_classify_active_start(
               &runtime, &journal, true, "start-1", "zone1", "node1", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_ACTIVE_START_DUPLICATE);
    assert(vg_dedicated_actuator_journal_classify_active_start(
               &runtime, &journal, true, "start-1", "zone1", "other-node", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_ACTIVE_START_KEY_CONFLICT);
    assert(vg_dedicated_actuator_journal_classify_active_start(
               &runtime, &journal, true, "start-1", "zone1", "node1", 1u, 1700000001
           ) == VG_DEDICATED_ACTUATOR_ACTIVE_START_KEY_CONFLICT);
    assert(vg_dedicated_actuator_journal_classify_active_start(
               &runtime, &journal, true, "start-2", "zone1", "node1", 1u, 1700000001
           ) == VG_DEDICATED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING);
    assert(vg_dedicated_actuator_journal_classify_active_start(
               &runtime, &journal, false, "start-1", "zone1", "node1", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING);

    const vg_dedicated_actuator_journal_runtime_state_t corrupt = trusted_runtime(
        VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CORRUPT
    );
    assert(vg_dedicated_actuator_journal_classify_active_start(
               &corrupt, &journal, true, "start-1", "zone1", "node1", 1u, 1700000000
           ) == VG_DEDICATED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING);
    assert(memcmp(before, records, sizeof(records)) == 0);
}

int main(void) {
    test_only_initialized_healthy_states_allow_start();
    test_duplicate_conflicts_and_lookup_are_read_only();
    test_full_and_unavailable_are_not_new_or_duplicates();
    test_active_line_start_ordering_is_read_only();
    return 0;
}
