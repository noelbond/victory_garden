#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define VG_ACTUATOR_TOPOLOGY_MAX_NODE_ID_LEN 32u
#define VG_ACTUATOR_TOPOLOGY_MAX_ZONE_ID_LEN 32u

typedef struct {
    bool assigned;
    bool active;
    char zone_id[VG_ACTUATOR_TOPOLOGY_MAX_ZONE_ID_LEN];
    char node_id[VG_ACTUATOR_TOPOLOGY_MAX_NODE_ID_LEN];
    uint8_t irrigation_line;
} vg_actuator_topology_assignment_t;

typedef enum {
    VG_ACTUATOR_TOPOLOGY_VALID = 0,
    VG_ACTUATOR_TOPOLOGY_INVALID_ARGUMENT,
    VG_ACTUATOR_TOPOLOGY_INVALID_CONFIG,
    VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL,
} vg_actuator_topology_result_t;

// Parses the retained actuator-config/v1 payload into assignments belonging
// only to local_zone_id. Caller-owned assignments are cleared on entry and on
// every invalid result, so callers can fail closed without retaining a stale
// topology. The zones[] field is intentionally not consulted.
vg_actuator_topology_result_t vg_actuator_topology_parse_v1(
    const char *payload,
    const char *local_zone_id,
    uint8_t supported_line_count,
    vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    uint8_t *configured_line_count_out,
    size_t *assignment_count_out
);

// Parses every supported node in the retained actuator-config/v1 payload.
// This is for a greenhouse-wide dedicated controller: node zone_id remains
// command/status identity metadata, while irrigation_line selects its output.
// Caller-owned assignments are cleared on entry and on every invalid result.
vg_actuator_topology_result_t vg_actuator_topology_parse_global_v1(
    const char *payload,
    uint8_t supported_line_count,
    vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    uint8_t *configured_line_count_out,
    size_t *assignment_count_out
);

bool vg_actuator_topology_lookup(
    const vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    const char *node_id,
    uint8_t *irrigation_line_out
);
