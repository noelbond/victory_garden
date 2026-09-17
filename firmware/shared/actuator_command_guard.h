#pragma once

#include <stdbool.h>

typedef enum {
    VG_ACTUATOR_COMMAND_GUARD_ACCEPT = 0,
    VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH,
    VG_ACTUATOR_COMMAND_GUARD_TOPOLOGY_UNAVAILABLE,
    VG_ACTUATOR_COMMAND_GUARD_MISSING_NODE,
} vg_actuator_command_guard_result_t;

// Validates the command identity fields after MQTT has parsed the command
// topic and payload. It intentionally does not parse MQTT, inspect topology
// assignments, or perform node-to-line lookup.
vg_actuator_command_guard_result_t vg_actuator_command_guard_validate(
    const char *local_zone_id,
    const char *topic_zone_id,
    const char *payload_zone_id,
    bool topology_ready,
    const char *node_id
);

// Greenhouse-wide controller variant. It validates the topic/payload Zone
// identity without assigning either Zone to the physical controller. Callers
// must still verify that the retained topology assigns node_id to this Zone.
vg_actuator_command_guard_result_t vg_actuator_command_guard_validate_global(
    const char *topic_zone_id,
    const char *payload_zone_id,
    bool topology_ready,
    const char *node_id
);
