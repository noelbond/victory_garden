#include <assert.h>
#include <stdio.h>

#include "actuator_command_guard.h"

static vg_actuator_command_guard_result_t validate(
    const char *topic_zone_id,
    const char *payload_zone_id,
    bool topology_ready,
    const char *node_id
) {
    return vg_actuator_command_guard_validate(
        "zone1", topic_zone_id, payload_zone_id, topology_ready, node_id
    );
}

static void test_matching_ready_command_is_accepted(void) {
    assert(validate("zone1", "zone1", true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ACCEPT);
}

static void test_foreign_topic_is_rejected(void) {
    assert(validate("zone2", "zone1", true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH);
    assert(validate("", "zone1", true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH);
    assert(validate(NULL, "zone1", true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH);
}

static void test_foreign_payload_is_rejected(void) {
    assert(validate("zone1", "zone2", true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH);
}

static void test_topic_payload_disagreement_is_rejected(void) {
    assert(validate("zone2", "zone3", true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH);
}

static void test_missing_payload_zone_is_rejected(void) {
    assert(validate("zone1", "", true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH);
    assert(validate("zone1", NULL, true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH);
}

static void test_topology_unavailable_precedes_missing_node(void) {
    assert(validate("zone1", "zone1", false, "") == VG_ACTUATOR_COMMAND_GUARD_TOPOLOGY_UNAVAILABLE);
}

static void test_ready_topology_requires_node(void) {
    assert(validate("zone1", "zone1", true, "") == VG_ACTUATOR_COMMAND_GUARD_MISSING_NODE);
    assert(validate("zone1", "zone1", true, NULL) == VG_ACTUATOR_COMMAND_GUARD_MISSING_NODE);
}

static void test_global_guard_accepts_any_matching_zone(void) {
    assert(vg_actuator_command_guard_validate_global(
               "zone2", "zone2", true, "zone2-node") == VG_ACTUATOR_COMMAND_GUARD_ACCEPT);
}

static void test_global_guard_rejects_topic_payload_disagreement(void) {
    assert(vg_actuator_command_guard_validate_global(
               "zone1", "zone2", true, "node1") == VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH);
}

int main(void) {
    test_matching_ready_command_is_accepted();
    test_foreign_topic_is_rejected();
    test_foreign_payload_is_rejected();
    test_topic_payload_disagreement_is_rejected();
    test_missing_payload_zone_is_rejected();
    test_topology_unavailable_precedes_missing_node();
    test_ready_topology_requires_node();
    test_global_guard_accepts_any_matching_zone();
    test_global_guard_rejects_topic_payload_disagreement();
    puts("actuator_command_guard_tests: passed");
    return 0;
}
