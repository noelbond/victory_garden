#pragma once

#include <stdbool.h>

// This policy is intentionally narrower than a general flash permission API.
// It protects only actuator runtime mutations until measured hardware timing
// can support the future active-output single-page-program exception.
typedef enum {
    VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM = 0,
    VG_ACTUATOR_FLASH_MUTATION_JOURNAL_SECTOR_ERASE,
    VG_ACTUATOR_FLASH_MUTATION_JOURNAL_COMPACTION,
    VG_ACTUATOR_FLASH_MUTATION_CONFIGURATION_SAVE,
} vg_actuator_flash_mutation_t;

typedef enum {
    VG_ACTUATOR_FLASH_MUTATION_ALLOWED = 0,
    VG_ACTUATOR_FLASH_MUTATION_ACTIVE_OUTPUT_BLOCKED,
    // No flash-program blackout duration is hardware-validated yet. This is
    // explicit rather than a numeric placeholder that could become authority.
    VG_ACTUATOR_FLASH_MUTATION_TIMING_GUARD_UNAVAILABLE,
} vg_actuator_flash_mutation_decision_t;

vg_actuator_flash_mutation_decision_t vg_actuator_flash_mutation_policy_decide(
    vg_actuator_flash_mutation_t mutation,
    bool any_output_active
);
