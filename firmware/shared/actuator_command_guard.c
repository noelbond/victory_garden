#include "actuator_command_guard.h"

#include <string.h>

vg_actuator_command_guard_result_t vg_actuator_command_guard_validate(
    const char *local_zone_id,
    const char *topic_zone_id,
    const char *payload_zone_id,
    bool topology_ready,
    const char *node_id
) {
    if (!local_zone_id || local_zone_id[0] == '\0' ||
        !topic_zone_id || topic_zone_id[0] == '\0' ||
        !payload_zone_id || payload_zone_id[0] == '\0' ||
        strcmp(topic_zone_id, local_zone_id) != 0 ||
        strcmp(payload_zone_id, local_zone_id) != 0 ||
        strcmp(topic_zone_id, payload_zone_id) != 0) {
        return VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH;
    }

    if (!topology_ready) {
        return VG_ACTUATOR_COMMAND_GUARD_TOPOLOGY_UNAVAILABLE;
    }

    if (!node_id || node_id[0] == '\0') {
        return VG_ACTUATOR_COMMAND_GUARD_MISSING_NODE;
    }

    return VG_ACTUATOR_COMMAND_GUARD_ACCEPT;
}

vg_actuator_command_guard_result_t vg_actuator_command_guard_validate_global(
    const char *topic_zone_id,
    const char *payload_zone_id,
    bool topology_ready,
    const char *node_id
) {
    if (!topic_zone_id || topic_zone_id[0] == '\0' ||
        !payload_zone_id || payload_zone_id[0] == '\0' ||
        strcmp(topic_zone_id, payload_zone_id) != 0) {
        return VG_ACTUATOR_COMMAND_GUARD_ZONE_MISMATCH;
    }

    if (!topology_ready) {
        return VG_ACTUATOR_COMMAND_GUARD_TOPOLOGY_UNAVAILABLE;
    }

    if (!node_id || node_id[0] == '\0') {
        return VG_ACTUATOR_COMMAND_GUARD_MISSING_NODE;
    }

    return VG_ACTUATOR_COMMAND_GUARD_ACCEPT;
}
