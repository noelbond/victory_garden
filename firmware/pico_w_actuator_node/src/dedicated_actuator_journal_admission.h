#pragma once

#include <stdint.h>

#include "actuator_start_journal.h"
#include "dedicated_actuator_journal_runtime_state.h"

// This is a read-only START admission classification. It never writes the
// reconstructed journal or its physical backing storage.
typedef enum {
    VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_UNAVAILABLE = 0,
    VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_NEW,
    VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE,
    VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT,
    VG_DEDICATED_ACTUATOR_JOURNAL_ADMISSION_FULL,
} vg_dedicated_actuator_journal_admission_t;

// Result used only after a START has resolved to an already-running output.
// It is intentionally limited to outcomes which may supersede
// ALREADY_RUNNING without mutating the journal or the active run.
typedef enum {
    VG_DEDICATED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING = 0,
    VG_DEDICATED_ACTUATOR_ACTIVE_START_DUPLICATE,
    VG_DEDICATED_ACTUATOR_ACTIVE_START_KEY_CONFLICT,
} vg_dedicated_actuator_active_start_result_t;

// Only initialized, authoritative storage states are valid START history.
// A blank region must not authorize START even if it is known empty: a later
// write-enabled step is responsible for establishing its durable authority.
bool vg_dedicated_actuator_journal_health_allows_start(
    const vg_dedicated_actuator_journal_runtime_state_t *runtime
);

// Classifies immutable START identity against reconstructed durable history.
// issued_at_epoch_seconds must already have passed canonical timestamp parsing;
// this function deliberately performs no trusted-time or freshness check.
vg_dedicated_actuator_journal_admission_t vg_dedicated_actuator_journal_classify_start(
    const vg_dedicated_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_t *journal,
    const char *idempotency_key,
    const char *zone_id,
    const char *node_id,
    uint8_t irrigation_line,
    int64_t issued_at_epoch_seconds
);

// Classifies a parsed immutable identity for an already-running output. An
// invalid identity, unavailable history, NEW identity, or full history keeps
// the established ALREADY_RUNNING result. This function is RAM read-only.
vg_dedicated_actuator_active_start_result_t
vg_dedicated_actuator_journal_classify_active_start(
    const vg_dedicated_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_t *journal,
    bool identity_is_valid,
    const char *idempotency_key,
    const char *zone_id,
    const char *node_id,
    uint8_t irrigation_line,
    int64_t issued_at_epoch_seconds
);
