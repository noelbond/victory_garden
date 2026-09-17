#include "dedicated_actuator_topology_transition.h"

#include <string.h>

bool vg_dedicated_actuator_topology_preserves_active_run(
    const vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    uint8_t irrigation_line_count,
    const char *active_zone_id,
    const char *active_node_id,
    uint8_t active_irrigation_line
) {
    if (!assignments || !active_zone_id || active_zone_id[0] == '\0' ||
        !active_node_id || active_node_id[0] == '\0' ||
        active_irrigation_line == 0 || active_irrigation_line > irrigation_line_count ||
        active_irrigation_line > assignment_capacity) {
        return false;
    }

    const vg_actuator_topology_assignment_t *assignment =
        &assignments[active_irrigation_line - 1u];
    return assignment->assigned &&
        assignment->irrigation_line == active_irrigation_line &&
        strcmp(assignment->zone_id, active_zone_id) == 0 &&
        strcmp(assignment->node_id, active_node_id) == 0;
}
