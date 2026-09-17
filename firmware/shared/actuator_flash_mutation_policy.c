#include "actuator_flash_mutation_policy.h"

vg_actuator_flash_mutation_decision_t vg_actuator_flash_mutation_policy_decide(
    vg_actuator_flash_mutation_t mutation,
    bool any_output_active
) {
    if (!any_output_active) {
        return VG_ACTUATOR_FLASH_MUTATION_ALLOWED;
    }

    switch (mutation) {
        case VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM:
            return VG_ACTUATOR_FLASH_MUTATION_TIMING_GUARD_UNAVAILABLE;
        case VG_ACTUATOR_FLASH_MUTATION_JOURNAL_SECTOR_ERASE:
        case VG_ACTUATOR_FLASH_MUTATION_JOURNAL_COMPACTION:
        case VG_ACTUATOR_FLASH_MUTATION_CONFIGURATION_SAVE:
        default:
            return VG_ACTUATOR_FLASH_MUTATION_ACTIVE_OUTPUT_BLOCKED;
    }
}
