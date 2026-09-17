#pragma once

#include <stdint.h>

// The Pico SDK deadline and alarm APIs both accept a uint32_t millisecond
// delay. Keep the proof for that conversion in one shared policy boundary.
#define VG_ACTUATOR_RUNTIME_MILLISECONDS_PER_SECOND UINT32_C(1000)

typedef enum {
    VG_ACTUATOR_START_RUNTIME_GUARD_VALID = 0,
    VG_ACTUATOR_START_RUNTIME_GUARD_INVALID_REQUEST,
    VG_ACTUATOR_START_RUNTIME_GUARD_LOCAL_RUNTIME_CAP_UNAVAILABLE,
    VG_ACTUATOR_START_RUNTIME_GUARD_UNREPRESENTABLE,
} vg_actuator_start_runtime_guard_result_t;

typedef struct {
    uint32_t effective_runtime_seconds;
    uint32_t effective_runtime_milliseconds;
} vg_actuator_start_runtime_guard_output_t;

// Validates a new START request against its configured local cap. A valid
// result includes the only millisecond delay callers may pass to the Pico SDK
// deadline and alarm APIs. The helper is deliberately independent of MQTT,
// configuration persistence, journals, and GPIO.
vg_actuator_start_runtime_guard_result_t vg_actuator_start_runtime_guard_validate(
    int requested_runtime_seconds,
    uint32_t configured_max_runtime_seconds,
    vg_actuator_start_runtime_guard_output_t *output
);
