#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "actuator_topology.h"

// Returns true only when a retained topology update preserves the exact
// routable identity of a currently active output. The caller must stop the
// active run before applying a topology for which this returns false.
bool vg_dedicated_actuator_topology_preserves_active_run(
    const vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    uint8_t irrigation_line_count,
    const char *active_zone_id,
    const char *active_node_id,
    uint8_t active_irrigation_line
);
