#include "actuator_start_runtime_guard.h"

#include <limits.h>

vg_actuator_start_runtime_guard_result_t vg_actuator_start_runtime_guard_validate(
    int requested_runtime_seconds,
    uint32_t configured_max_runtime_seconds,
    vg_actuator_start_runtime_guard_output_t *output
) {
    if (output) {
        output->effective_runtime_seconds = 0u;
        output->effective_runtime_milliseconds = 0u;
    }

    if (!output || requested_runtime_seconds <= 0) {
        return VG_ACTUATOR_START_RUNTIME_GUARD_INVALID_REQUEST;
    }
    if (configured_max_runtime_seconds == 0u) {
        return VG_ACTUATOR_START_RUNTIME_GUARD_LOCAL_RUNTIME_CAP_UNAVAILABLE;
    }

    const uint32_t requested_seconds = (uint32_t)requested_runtime_seconds;
    const uint32_t effective_seconds = requested_seconds > configured_max_runtime_seconds
        ? configured_max_runtime_seconds
        : requested_seconds;

    if (effective_seconds > UINT32_MAX / VG_ACTUATOR_RUNTIME_MILLISECONDS_PER_SECOND) {
        return VG_ACTUATOR_START_RUNTIME_GUARD_UNREPRESENTABLE;
    }

    output->effective_runtime_seconds = effective_seconds;
    output->effective_runtime_milliseconds =
        effective_seconds * VG_ACTUATOR_RUNTIME_MILLISECONDS_PER_SECOND;
    return VG_ACTUATOR_START_RUNTIME_GUARD_VALID;
}
