#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "actuator_start_journal_storage.h"

typedef enum {
    VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_BLANK = 0,
    VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_EMPTY,
    VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_HEALTHY_WITH_RECORDS,
    VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_CLEANUP_REQUIRED,
    VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_CORRUPT,
    VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_UNSUPPORTED,
    VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE,
} vg_combined_actuator_journal_health_t;

typedef struct {
    vg_combined_actuator_journal_health_t health;
    bool durable_history_trustworthy;
    bool cleanup_required;
    size_t authoritative_bank;
    size_t record_count;
    uint64_t sequence_high_water;
} vg_combined_actuator_journal_runtime_state_t;

void vg_combined_actuator_journal_runtime_state_from_storage(
    vg_combined_actuator_journal_runtime_state_t *runtime,
    const vg_actuator_start_journal_storage_t *storage,
    bool backend_read_failed
);

const char *vg_combined_actuator_journal_health_name(
    vg_combined_actuator_journal_health_t health
);
