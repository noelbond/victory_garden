#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "actuator_start_runtime_guard.h"
#include "json_lite.h"

static vg_actuator_start_runtime_guard_result_t validate(
    int requested_runtime_seconds,
    uint32_t configured_max_runtime_seconds,
    vg_actuator_start_runtime_guard_output_t *output
) {
    return vg_actuator_start_runtime_guard_validate(
        requested_runtime_seconds, configured_max_runtime_seconds, output
    );
}

static void test_zero_configured_cap_is_unavailable(void) {
    vg_actuator_start_runtime_guard_output_t output = {0};
    assert(validate(60, 0u, &output) ==
           VG_ACTUATOR_START_RUNTIME_GUARD_LOCAL_RUNTIME_CAP_UNAVAILABLE);
    assert(output.effective_runtime_seconds == 0u);
    assert(output.effective_runtime_milliseconds == 0u);
}

static void test_runtime_under_cap_is_preserved(void) {
    vg_actuator_start_runtime_guard_output_t output = {0};
    assert(validate(60, 120u, &output) == VG_ACTUATOR_START_RUNTIME_GUARD_VALID);
    assert(output.effective_runtime_seconds == 60u);
    assert(output.effective_runtime_milliseconds == 60000u);
}

static void test_runtime_over_cap_is_clamped(void) {
    vg_actuator_start_runtime_guard_output_t output = {0};
    assert(validate(300, 120u, &output) == VG_ACTUATOR_START_RUNTIME_GUARD_VALID);
    assert(output.effective_runtime_seconds == 120u);
    assert(output.effective_runtime_milliseconds == 120000u);
}

static void test_non_positive_request_is_invalid(void) {
    vg_actuator_start_runtime_guard_output_t output = {0};
    assert(validate(0, 120u, &output) == VG_ACTUATOR_START_RUNTIME_GUARD_INVALID_REQUEST);
    assert(validate(-1, 120u, &output) == VG_ACTUATOR_START_RUNTIME_GUARD_INVALID_REQUEST);
}

static void test_runtime_json_must_be_a_representable_integer(void) {
    int parsed = 0;
    assert(extract_json_int("{\"runtime_seconds\":2147483647}",
                            "runtime_seconds", &parsed));
    assert(parsed == INT_MAX);
    assert(!extract_json_int("{\"runtime_seconds\":2147483648}",
                             "runtime_seconds", &parsed));
    assert(!extract_json_int("{\"runtime_seconds\":1.5}",
                             "runtime_seconds", &parsed));
    assert(!extract_json_int("{\"runtime_seconds\":1e3}",
                             "runtime_seconds", &parsed));
}

static void test_int_max_request_is_safely_clamped(void) {
    vg_actuator_start_runtime_guard_output_t output = {0};
    assert(validate(INT_MAX, 120u, &output) == VG_ACTUATOR_START_RUNTIME_GUARD_VALID);
    assert(output.effective_runtime_seconds == 120u);
    assert(output.effective_runtime_milliseconds == 120000u);
}

static void test_largest_representable_delay_is_safe(void) {
    vg_actuator_start_runtime_guard_output_t output = {0};
    const uint32_t max_seconds =
        UINT32_MAX / VG_ACTUATOR_RUNTIME_MILLISECONDS_PER_SECOND;

    assert(validate(INT_MAX, max_seconds, &output) ==
           VG_ACTUATOR_START_RUNTIME_GUARD_VALID);
    assert(output.effective_runtime_seconds == max_seconds);
    assert(output.effective_runtime_milliseconds ==
           max_seconds * VG_ACTUATOR_RUNTIME_MILLISECONDS_PER_SECOND);
    assert(validate(INT_MAX, max_seconds + 1u, &output) ==
           VG_ACTUATOR_START_RUNTIME_GUARD_UNREPRESENTABLE);
}

int main(void) {
    test_zero_configured_cap_is_unavailable();
    test_runtime_under_cap_is_preserved();
    test_runtime_over_cap_is_clamped();
    test_non_positive_request_is_invalid();
    test_runtime_json_must_be_a_representable_integer();
    test_int_max_request_is_safely_clamped();
    test_largest_representable_delay_is_safe();
    puts("actuator_start_runtime_guard_tests: passed");
    return 0;
}
