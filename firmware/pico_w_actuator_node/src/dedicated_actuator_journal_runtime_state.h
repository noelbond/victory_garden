#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "actuator_start_journal_storage.h"

typedef enum {
    VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BLANK = 0,
    VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY,
    VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS,
    VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED,
    VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CORRUPT,
    VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_UNSUPPORTED,
    VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE,
} vg_dedicated_actuator_journal_health_t;

typedef struct {
    vg_dedicated_actuator_journal_health_t health;
    // Only initialized storage whose reconstructed accepted records are
    // authoritative may permit START. A blank dual-bank region is known-empty
    // but not yet durable START authority.
    bool durable_history_trustworthy;
    bool cleanup_required;
    size_t authoritative_bank;
    size_t record_count;
    uint64_t sequence_high_water;
} vg_dedicated_actuator_journal_runtime_state_t;

// Maps the shared storage manager's read-only scan result to the dedicated
// runtime's diagnostic state. A physical read failure takes precedence over a
// partial scan result because durable history then cannot be trusted.
void vg_dedicated_actuator_journal_runtime_state_from_storage(
    vg_dedicated_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_storage_t *storage,
    bool backend_read_failed
);

const char *vg_dedicated_actuator_journal_health_name(
    vg_dedicated_actuator_journal_health_t health
);
