#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

#include "actuator_command_freshness.h"
#include "actuator_start_journal.h"

#define TEST_CAPACITY 2u
#define ISSUED_AT_ONE 1000
#define ISSUED_AT_TWO 2000

static vg_actuator_start_journal_result_t prepare(
    const vg_actuator_start_journal_t *journal,
    const char *key,
    const char *zone,
    const char *node,
    uint8_t line,
    int64_t issued_at_epoch_seconds,
    vg_actuator_start_journal_candidate_t *candidate
) {
    return vg_actuator_start_journal_prepare(
        journal, key, zone, node, line, issued_at_epoch_seconds, candidate
    );
}

static void init_empty(vg_actuator_start_journal_t *journal,
                       vg_actuator_start_journal_record_t *records,
                       size_t capacity) {
    memset(records, 0, capacity * sizeof(*records));
    assert(vg_actuator_start_journal_init(journal, records, capacity));
}

static void accept(vg_actuator_start_journal_t *journal, const char *key,
                   const char *zone, const char *node, uint8_t line,
                   int64_t issued_at_epoch_seconds) {
    vg_actuator_start_journal_candidate_t candidate;
    assert(prepare(journal, key, zone, node, line, issued_at_epoch_seconds, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
    // The test record array models data that a future adapter would persist
    // and verify before this explicit commit step.
    assert(vg_actuator_start_journal_commit_verified(journal, &candidate));
}

static void test_unseen_key_is_new_but_not_seen_until_committed(void) {
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    vg_actuator_start_journal_candidate_t candidate;
    init_empty(&journal, records, TEST_CAPACITY);

    assert(prepare(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
    assert(candidate.prepared);
    assert(candidate.record.issued_at_epoch_seconds == ISSUED_AT_ONE);
    assert(!records[0].accepted);
    assert(prepare(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
}

static void test_committed_record_stores_timestamp_and_exact_duplicate(void) {
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    vg_actuator_start_journal_candidate_t candidate;
    init_empty(&journal, records, TEST_CAPACITY);
    accept(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE);

    assert(records[0].issued_at_epoch_seconds == ISSUED_AT_ONE);
    assert(prepare(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_DUPLICATE);
}

static void test_same_key_with_different_binding_or_timestamp_is_conflict(void) {
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    vg_actuator_start_journal_candidate_t candidate;
    init_empty(&journal, records, TEST_CAPACITY);
    accept(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE);

    assert(prepare(&journal, "key-1", "zone2", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_KEY_CONFLICT);
    assert(prepare(&journal, "key-1", "zone1", "node2", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_KEY_CONFLICT);
    assert(prepare(&journal, "key-1", "zone1", "node1", 2, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_KEY_CONFLICT);
    assert(prepare(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_TWO, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_KEY_CONFLICT);
}

static void test_full_journal_preserves_duplicate_without_automatic_pruning(void) {
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    vg_actuator_start_journal_candidate_t candidate;
    init_empty(&journal, records, TEST_CAPACITY);
    accept(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE);
    accept(&journal, "key-2", "zone1", "node2", 2, ISSUED_AT_TWO);

    assert(prepare(&journal, "key-3", "zone1", "node3", 3, ISSUED_AT_TWO, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_FULL);
    assert(prepare(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_DUPLICATE);
}

static void test_reboot_load_preserves_timestamp_and_duplicate_behavior(void) {
    vg_actuator_start_journal_record_t durable_records[TEST_CAPACITY];
    vg_actuator_start_journal_t first_boot;
    vg_actuator_start_journal_t rebooted;
    vg_actuator_start_journal_candidate_t candidate;
    init_empty(&first_boot, durable_records, TEST_CAPACITY);
    accept(&first_boot, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE);

    assert(vg_actuator_start_journal_init(&rebooted, durable_records, TEST_CAPACITY));
    assert(durable_records[0].issued_at_epoch_seconds == ISSUED_AT_ONE);
    assert(prepare(&rebooted, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_DUPLICATE);
}

static void test_uncommitted_candidate_is_not_seen_after_reboot(void) {
    vg_actuator_start_journal_record_t durable_records[TEST_CAPACITY];
    vg_actuator_start_journal_t first_boot;
    vg_actuator_start_journal_t rebooted;
    vg_actuator_start_journal_candidate_t candidate;
    init_empty(&first_boot, durable_records, TEST_CAPACITY);

    assert(prepare(&first_boot, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
    assert(!vg_actuator_start_journal_commit_verified(&first_boot, NULL));
    assert(vg_actuator_start_journal_init(&rebooted, durable_records, TEST_CAPACITY));
    assert(prepare(&rebooted, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
}

static void test_invalid_input_and_unsupported_loaded_record_version_fail_closed(void) {
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    vg_actuator_start_journal_candidate_t candidate;
    char too_long_key[VG_ACTUATOR_START_JOURNAL_MAX_IDEMPOTENCY_KEY_LEN];
    init_empty(&journal, records, TEST_CAPACITY);

    assert(prepare(&journal, NULL, "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_INVALID_ARGUMENT);
    assert(prepare(&journal, "", "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_INVALID_ARGUMENT);
    assert(prepare(&journal, "key-1", "", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_INVALID_ARGUMENT);
    assert(prepare(&journal, "key-1", "zone1", NULL, 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_INVALID_ARGUMENT);
    assert(prepare(&journal, "key-1", "zone1", "node1", 0, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_INVALID_ARGUMENT);

    memset(too_long_key, 'x', sizeof(too_long_key));
    assert(prepare(&journal, too_long_key, "zone1", "node1", 1, ISSUED_AT_ONE, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_INVALID_ARGUMENT);

    accept(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE);
    records[0].version = 1u;
    assert(prepare(&journal, "key-2", "zone1", "node2", 2, ISSUED_AT_TWO, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_INVALID_RECORD);
}

static void test_pruning_boundaries_and_untrusted_time(void) {
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    init_empty(&journal, records, TEST_CAPACITY);
    accept(&journal, "key-1", "zone1", "node1", 1, ISSUED_AT_ONE);

    assert(vg_actuator_start_journal_prune(&journal, ISSUED_AT_ONE + 29, true) == 0);
    assert(records[0].accepted);
    assert(vg_actuator_start_journal_prune(&journal, ISSUED_AT_ONE + 30, true) == 0);
    assert(records[0].accepted);
    assert(vg_actuator_start_journal_prune(&journal, ISSUED_AT_ONE + 31, false) == 0);
    assert(records[0].accepted);
    assert(vg_actuator_start_journal_prune(&journal, ISSUED_AT_ONE + 31, true) == 1);
    assert(!records[0].accepted);
}

static void test_pruning_only_removes_expired_records_and_creates_capacity(void) {
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    vg_actuator_start_journal_candidate_t candidate;
    init_empty(&journal, records, TEST_CAPACITY);
    accept(&journal, "expired", "zone1", "node1", 1, ISSUED_AT_ONE);
    accept(&journal, "retained", "zone1", "node2", 2, ISSUED_AT_TWO);

    assert(prepare(&journal, "new", "zone1", "node3", 3, ISSUED_AT_TWO, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_FULL);
    assert(vg_actuator_start_journal_prune(&journal, ISSUED_AT_ONE + 31, true) == 1);
    assert(!records[0].accepted);
    assert(records[1].accepted);
    assert(strcmp(records[1].idempotency_key, "retained") == 0);
    assert(prepare(&journal, "new", "zone1", "node3", 3, ISSUED_AT_ONE + 31, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
}

static void test_arithmetic_boundaries_do_not_prune_early(void) {
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    init_empty(&journal, records, TEST_CAPACITY);
    accept(&journal, "key-high", "zone1", "node1", 1, INT64_MAX);
    assert(!vg_actuator_start_journal_record_is_safe_to_prune(&records[0], INT64_MAX, true));

    memset(records, 0, sizeof(records));
    accept(&journal, "key-low", "zone1", "node1", 1, INT64_MIN);
    assert(!vg_actuator_start_journal_record_is_safe_to_prune(&records[0], INT64_MIN + 30, true));
    assert(vg_actuator_start_journal_record_is_safe_to_prune(&records[0], INT64_MIN + 31, true));
}

static void test_replay_after_safe_pruning_is_stale_by_freshness_policy(void) {
    static const char *const issued_at = "2026-09-14T16:52:12Z";
    static const int64_t issued_at_epoch_seconds = 1789404732;
    vg_actuator_start_journal_record_t records[TEST_CAPACITY];
    vg_actuator_start_journal_t journal;
    vg_actuator_start_journal_candidate_t candidate;
    init_empty(&journal, records, TEST_CAPACITY);
    accept(&journal, "key-1", "zone1", "node1", 1, issued_at_epoch_seconds);

    assert(vg_actuator_start_journal_prune(&journal, issued_at_epoch_seconds + 31, true) == 1);
    assert(prepare(&journal, "key-1", "zone1", "node1", 1, issued_at_epoch_seconds, &candidate) ==
           VG_ACTUATOR_START_JOURNAL_NEW);
    assert(vg_actuator_command_validate_start_freshness(
               issued_at, issued_at_epoch_seconds + 31, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_STALE);
}

int main(void) {
    test_unseen_key_is_new_but_not_seen_until_committed();
    test_committed_record_stores_timestamp_and_exact_duplicate();
    test_same_key_with_different_binding_or_timestamp_is_conflict();
    test_full_journal_preserves_duplicate_without_automatic_pruning();
    test_reboot_load_preserves_timestamp_and_duplicate_behavior();
    test_uncommitted_candidate_is_not_seen_after_reboot();
    test_invalid_input_and_unsupported_loaded_record_version_fail_closed();
    test_pruning_boundaries_and_untrusted_time();
    test_pruning_only_removes_expired_records_and_creates_capacity();
    test_arithmetic_boundaries_do_not_prune_early();
    test_replay_after_safe_pruning_is_stale_by_freshness_policy();
    puts("actuator_start_journal_tests: passed");
    return 0;
}
