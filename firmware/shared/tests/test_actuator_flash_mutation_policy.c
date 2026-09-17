#include <assert.h>

#include "actuator_flash_mutation_policy.h"

static void test_idle_mutations_are_allowed(void) {
    assert(vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM, false
           ) == VG_ACTUATOR_FLASH_MUTATION_ALLOWED);
    assert(vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_JOURNAL_SECTOR_ERASE, false
           ) == VG_ACTUATOR_FLASH_MUTATION_ALLOWED);
    assert(vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_JOURNAL_COMPACTION, false
           ) == VG_ACTUATOR_FLASH_MUTATION_ALLOWED);
    assert(vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_CONFIGURATION_SAVE, false
           ) == VG_ACTUATOR_FLASH_MUTATION_ALLOWED);
}

static void test_active_outputs_block_mutations_without_a_numeric_guard(void) {
    assert(vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM, true
           ) == VG_ACTUATOR_FLASH_MUTATION_TIMING_GUARD_UNAVAILABLE);
    assert(vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_JOURNAL_SECTOR_ERASE, true
           ) == VG_ACTUATOR_FLASH_MUTATION_ACTIVE_OUTPUT_BLOCKED);
    assert(vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_JOURNAL_COMPACTION, true
           ) == VG_ACTUATOR_FLASH_MUTATION_ACTIVE_OUTPUT_BLOCKED);
    assert(vg_actuator_flash_mutation_policy_decide(
               VG_ACTUATOR_FLASH_MUTATION_CONFIGURATION_SAVE, true
           ) == VG_ACTUATOR_FLASH_MUTATION_ACTIVE_OUTPUT_BLOCKED);
}

int main(void) {
    test_idle_mutations_are_allowed();
    test_active_outputs_block_mutations_without_a_numeric_guard();
    return 0;
}
