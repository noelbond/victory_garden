#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "actuator_command_freshness.h"

static const char *const NOW = "2026-09-14T16:52:12Z";
static const int64_t NOW_EPOCH = 1789404732;

static void assert_epoch(const char *issued_at, int64_t expected_epoch) {
    int64_t epoch = 0;
    assert(vg_actuator_command_parse_issued_at(issued_at, &epoch));
    assert(epoch == expected_epoch);
}

static void assert_invalid_timestamp(const char *issued_at) {
    int64_t epoch = 0;
    assert(!vg_actuator_command_parse_issued_at(issued_at, &epoch));
}

static void test_known_epoch_vectors(void) {
    assert_epoch("1969-12-31T23:59:59Z", -1);
    assert_epoch("1970-01-01T00:00:00Z", 0);
    assert_epoch("2000-01-01T00:00:00Z", 946684800);
    assert_epoch("2020-02-29T00:00:00Z", 1582934400);
    assert_epoch(NOW, NOW_EPOCH);
}

static void test_calendar_validation(void) {
    assert_epoch("2024-02-29T12:34:56Z", 1709210096);
    assert_invalid_timestamp("2023-02-29T12:34:56Z");
    assert_invalid_timestamp("2026-00-14T16:52:12Z");
    assert_invalid_timestamp("2026-13-14T16:52:12Z");
    assert_invalid_timestamp("2026-04-31T16:52:12Z");
    assert_invalid_timestamp("2026-09-14T24:52:12Z");
    assert_invalid_timestamp("2026-09-14T16:60:12Z");
    assert_invalid_timestamp("2026-09-14T16:52:60Z");
}

static void test_wire_format_is_exact(void) {
    assert_invalid_timestamp("2026-09-14T16:52:12.000Z");
    assert_invalid_timestamp("2026-09-14T16:52:12+00:00");
    assert_invalid_timestamp("2026-09-14T16:52:12");
    assert_invalid_timestamp("2026-09-14 16:52:12Z");
    assert_invalid_timestamp("202x-09-14T16:52:12Z");
    assert_invalid_timestamp("2026/09/14T16:52:12Z");
    assert_invalid_timestamp("");
    assert_invalid_timestamp(NULL);
    assert(!vg_actuator_command_parse_issued_at(NOW, NULL));
}

static void test_freshness_boundaries(void) {
    assert(vg_actuator_command_validate_start_freshness(NOW, NOW_EPOCH, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_FRESH);
    assert(vg_actuator_command_validate_start_freshness("2026-09-14T16:52:11Z", NOW_EPOCH, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_FRESH);
    assert(vg_actuator_command_validate_start_freshness("2026-09-14T16:51:52Z", NOW_EPOCH, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_FRESH);
    assert(vg_actuator_command_validate_start_freshness("2026-09-14T16:51:51Z", NOW_EPOCH, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_STALE);
    assert(vg_actuator_command_validate_start_freshness("2026-09-14T16:52:17Z", NOW_EPOCH, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_FRESH);
    assert(vg_actuator_command_validate_start_freshness("2026-09-14T16:52:18Z", NOW_EPOCH, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_FUTURE);
}

static void test_untrusted_time_precedes_timestamp_validation(void) {
    assert(vg_actuator_command_validate_start_freshness(NOW, NOW_EPOCH, false) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_TIME_NOT_TRUSTED);
    assert(vg_actuator_command_validate_start_freshness("not-a-timestamp", NOW_EPOCH, false) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_TIME_NOT_TRUSTED);
}

static void test_invalid_timestamp_is_classified(void) {
    assert(vg_actuator_command_validate_start_freshness("2026-09-14T16:52:12.000Z", NOW_EPOCH, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_INVALID_TIMESTAMP);
}

static void test_comparisons_do_not_overflow_or_underflow(void) {
    assert(vg_actuator_command_validate_start_freshness("9999-12-31T23:59:59Z", INT64_MAX, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_STALE);
    assert(vg_actuator_command_validate_start_freshness("0001-01-01T00:00:00Z", INT64_MIN, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_FUTURE);
    assert(vg_actuator_command_validate_start_freshness("0001-01-01T00:00:00Z", -62135596800, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_FRESH);
    assert(vg_actuator_command_validate_start_freshness("9999-12-31T23:59:59Z", 253402300799, true) ==
           VG_ACTUATOR_COMMAND_FRESHNESS_FRESH);
}

int main(void) {
    test_known_epoch_vectors();
    test_calendar_validation();
    test_wire_format_is_exact();
    test_freshness_boundaries();
    test_untrusted_time_precedes_timestamp_validation();
    test_invalid_timestamp_is_classified();
    test_comparisons_do_not_overflow_or_underflow();
    puts("actuator_command_freshness_tests: passed");
    return 0;
}
