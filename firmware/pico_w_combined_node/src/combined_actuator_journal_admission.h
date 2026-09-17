#pragma once

#include "actuator_start_journal.h"
#include "combined_actuator_journal_runtime_state.h"

typedef enum {
    VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_UNAVAILABLE = 0,
    VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_NEW,
    VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE,
    VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_KEY_CONFLICT,
    VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_FULL,
} vg_combined_actuator_journal_admission_t;

// Result used only after a START has resolved to an already-running output.
// It is intentionally limited to outcomes which may supersede
// ALREADY_RUNNING without mutating the journal or the active run.
typedef enum {
    VG_COMBINED_ACTUATOR_ACTIVE_START_ALREADY_RUNNING = 0,
    VG_COMBINED_ACTUATOR_ACTIVE_START_DUPLICATE,
    VG_COMBINED_ACTUATOR_ACTIVE_START_KEY_CONFLICT,
} vg_combined_actuator_active_start_result_t;

bool vg_combined_actuator_journal_health_allows_start(
    const vg_combined_actuator_journal_runtime_state_t *runtime);
vg_combined_actuator_journal_admission_t vg_combined_actuator_journal_classify_start(
    const vg_combined_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_t *journal,
    const char *idempotency_key, const char *zone_id, const char *node_id,
    uint8_t irrigation_line, int64_t issued_at_epoch_seconds);

// Classifies a parsed immutable identity for an already-running output. An
// invalid identity, unavailable history, NEW identity, or full history keeps
// the established ALREADY_RUNNING result. This function is RAM read-only.
vg_combined_actuator_active_start_result_t
vg_combined_actuator_journal_classify_active_start(
    const vg_combined_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_t *journal,
    bool identity_is_valid,
    const char *idempotency_key, const char *zone_id, const char *node_id,
    uint8_t irrigation_line, int64_t issued_at_epoch_seconds);
