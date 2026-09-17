#pragma once

#include <stdbool.h>
#include <stdint.h>

// START commands are valid only within this bounded window around trusted UTC.
#define VG_ACTUATOR_COMMAND_MAX_START_AGE_SECONDS 20
#define VG_ACTUATOR_COMMAND_MAX_FUTURE_SKEW_SECONDS 5

typedef enum {
    VG_ACTUATOR_COMMAND_FRESHNESS_FRESH = 0,
    VG_ACTUATOR_COMMAND_FRESHNESS_STALE,
    VG_ACTUATOR_COMMAND_FRESHNESS_FUTURE,
    VG_ACTUATOR_COMMAND_FRESHNESS_INVALID_TIMESTAMP,
    VG_ACTUATOR_COMMAND_FRESHNESS_TIME_NOT_TRUSTED,
} vg_actuator_command_freshness_result_t;

// Parses exactly YYYY-MM-DDTHH:MM:SSZ as a UTC Unix epoch in seconds. The
// conversion is deterministic and does not depend on the host timezone.
bool vg_actuator_command_parse_issued_at(
    const char *issued_at,
    int64_t *epoch_seconds_out
);

// Classifies an unseen START against caller-supplied UTC trust and time. This
// module has no journal or runtime dependencies; callers handle duplicates
// before invoking it.
vg_actuator_command_freshness_result_t vg_actuator_command_validate_start_freshness(
    const char *issued_at,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time
);
