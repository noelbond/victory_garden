#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "dedicated_actuator_topology_transition.h"

#define TEST_CAPACITY 8u

static void assign(
    vg_actuator_topology_assignment_t *assignments,
    uint8_t line,
    const char *zone_id,
    const char *node_id
) {
    vg_actuator_topology_assignment_t *assignment = &assignments[line - 1u];
    assignment->assigned = true;
    assignment->irrigation_line = line;
    snprintf(assignment->zone_id, sizeof(assignment->zone_id), "%s", zone_id);
    snprintf(assignment->node_id, sizeof(assignment->node_id), "%s", node_id);
}

static void test_identical_mapping_preserves_active_run(void) {
    vg_actuator_topology_assignment_t assignments[TEST_CAPACITY] = {0};
    assign(assignments, 1u, "zone-a", "package-a-ch0");

    assert(vg_dedicated_actuator_topology_preserves_active_run(
        assignments, TEST_CAPACITY, 4u, "zone-a", "package-a-ch0", 1u
    ));
}

static void test_removed_or_remapped_mapping_does_not_preserve_active_run(void) {
    vg_actuator_topology_assignment_t removed[TEST_CAPACITY] = {0};
    assert(!vg_dedicated_actuator_topology_preserves_active_run(
        removed, TEST_CAPACITY, 4u, "zone-a", "package-a-ch0", 1u
    ));

    vg_actuator_topology_assignment_t remapped[TEST_CAPACITY] = {0};
    assign(remapped, 2u, "zone-a", "package-a-ch0");
    assert(!vg_dedicated_actuator_topology_preserves_active_run(
        remapped, TEST_CAPACITY, 4u, "zone-a", "package-a-ch0", 1u
    ));
}

static void test_capacity_reduction_and_zone_change_do_not_preserve_active_run(void) {
    vg_actuator_topology_assignment_t assignments[TEST_CAPACITY] = {0};
    assign(assignments, 5u, "zone-a", "package-a-ch0");
    assert(!vg_dedicated_actuator_topology_preserves_active_run(
        assignments, TEST_CAPACITY, 4u, "zone-a", "package-a-ch0", 5u
    ));

    assign(assignments, 1u, "zone-b", "package-a-ch0");
    assert(!vg_dedicated_actuator_topology_preserves_active_run(
        assignments, TEST_CAPACITY, 8u, "zone-a", "package-a-ch0", 1u
    ));
}

static void test_unrelated_change_preserves_active_run(void) {
    vg_actuator_topology_assignment_t assignments[TEST_CAPACITY] = {0};
    assign(assignments, 1u, "zone-a", "package-a-ch0");
    assign(assignments, 5u, "zone-b", "package-b-ch0");

    assert(vg_dedicated_actuator_topology_preserves_active_run(
        assignments, TEST_CAPACITY, 8u, "zone-a", "package-a-ch0", 1u
    ));
}

static void test_zone_deactivation_removes_only_that_zones_route(void) {
    vg_actuator_topology_assignment_t deactivated_topology[TEST_CAPACITY] = {0};
    assign(deactivated_topology, 5u, "zone-b", "package-b-ch0");

    assert(!vg_dedicated_actuator_topology_preserves_active_run(
        deactivated_topology, TEST_CAPACITY, 8u, "zone-a", "package-a-ch0", 1u
    ));
    assert(vg_dedicated_actuator_topology_preserves_active_run(
        deactivated_topology, TEST_CAPACITY, 8u, "zone-b", "package-b-ch0", 5u
    ));
}

int main(void) {
    test_identical_mapping_preserves_active_run();
    test_removed_or_remapped_mapping_does_not_preserve_active_run();
    test_capacity_reduction_and_zone_change_do_not_preserve_active_run();
    test_unrelated_change_preserves_active_run();
    test_zone_deactivation_removes_only_that_zones_route();
    puts("dedicated_actuator_topology_transition_tests: passed");
    return 0;
}
