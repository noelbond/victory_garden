#include "actuator_topology.h"

#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "json_lite.h"

static bool object_json_string(const char *object_start, const char *object_end, const char *key,
                               char *out, size_t out_size) {
    char field_name[48];
    snprintf(field_name, sizeof(field_name), "\"%s\":", key);
    const char *field = strstr(object_start, field_name);
    if (!field || field >= object_end) {
        return false;
    }

    const char *after_value = NULL;
    const char *value = field + strlen(field_name);
    if (*value != '"' || !decode_json_string(value + 1, out, out_size, &after_value)) {
        return false;
    }
    return after_value && after_value <= object_end;
}

static bool object_json_int(const char *object_start, const char *object_end, const char *key, int *out) {
    char field_name[48];
    snprintf(field_name, sizeof(field_name), "\"%s\":", key);
    const char *field = strstr(object_start, field_name);
    if (!field || field >= object_end) {
        return false;
    }

    char *after_value = NULL;
    long value = strtol(field + strlen(field_name), &after_value, 10);
    if (after_value == field + strlen(field_name) || after_value > object_end ||
        value < INT_MIN || value > INT_MAX) {
        return false;
    }
    *out = (int)value;
    return true;
}

static bool object_json_bool(const char *object_start, const char *object_end, const char *key, bool *out) {
    char field_name[48];
    snprintf(field_name, sizeof(field_name), "\"%s\":", key);
    const char *field = strstr(object_start, field_name);
    if (!field || field >= object_end) {
        return false;
    }

    const char *value = field + strlen(field_name);
    if (value + 4 <= object_end && strncmp(value, "true", 4) == 0) {
        *out = true;
        return true;
    }
    if (value + 5 <= object_end && strncmp(value, "false", 5) == 0) {
        *out = false;
        return true;
    }
    return false;
}

static bool assignment_node_id_seen(const vg_actuator_topology_assignment_t *assignments,
                                    size_t assignment_capacity, const char *node_id) {
    for (size_t i = 0; i < assignment_capacity; ++i) {
        if (assignments[i].assigned && strcmp(assignments[i].node_id, node_id) == 0) {
            return true;
        }
    }
    return false;
}

static vg_actuator_topology_result_t parse_v1(
    const char *payload,
    const char *local_zone_id,
    bool local_only,
    uint8_t supported_line_count,
    vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    uint8_t *configured_line_count_out,
    size_t *assignment_count_out
) {
    if (!assignments || assignment_capacity == 0 || !configured_line_count_out || !assignment_count_out) {
        return VG_ACTUATOR_TOPOLOGY_INVALID_ARGUMENT;
    }

    memset(assignments, 0, assignment_capacity * sizeof(*assignments));
    *configured_line_count_out = 0;
    *assignment_count_out = 0;

    char schema[32] = {0};
    int irrigation_line_count = 0;
    if (!payload || (local_only && !local_zone_id) ||
        !extract_json_string(payload, "schema_version", schema, sizeof(schema)) ||
        strcmp(schema, "actuator-config/v1") != 0 ||
        !extract_json_int(payload, "irrigation_line_count", &irrigation_line_count) ||
        irrigation_line_count < 0 || irrigation_line_count > (int)supported_line_count ||
        irrigation_line_count > (int)assignment_capacity) {
        return VG_ACTUATOR_TOPOLOGY_INVALID_CONFIG;
    }

    const char *nodes_array = strstr(payload, "\"nodes\":[");
    if (!nodes_array) {
        *configured_line_count_out = (uint8_t)irrigation_line_count;
        return VG_ACTUATOR_TOPOLOGY_VALID;
    }

    const char *cursor = strchr(nodes_array, '[');
    const char *array_end = cursor ? strchr(cursor, ']') : NULL;
    if (!cursor || !array_end) {
        return VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL;
    }

    ++cursor;
    while (cursor < array_end) {
        const char *object_start = strchr(cursor, '{');
        if (!object_start || object_start >= array_end) {
            break;
        }
        const char *object_end = strchr(object_start, '}');
        if (!object_end || object_end > array_end) {
            memset(assignments, 0, assignment_capacity * sizeof(*assignments));
            *assignment_count_out = 0;
            return VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL;
        }

        vg_actuator_topology_assignment_t assignment = {0};
        int line_number = 0;
        bool active = false;
        bool has_zone = object_json_string(object_start, object_end, "zone_id", assignment.zone_id, sizeof(assignment.zone_id));

        // The legacy local parser ignores foreign entries. The greenhouse-wide
        // parser owns every route, so each entry must identify its Zone and
        // participates in global duplicate-line/node validation.
        if (local_only && (!has_zone || strcmp(assignment.zone_id, local_zone_id) != 0)) {
            cursor = object_end + 1;
            continue;
        }

        if (!has_zone || assignment.zone_id[0] == '\0' ||
            !object_json_string(object_start, object_end, "node_id", assignment.node_id, sizeof(assignment.node_id)) ||
            assignment.node_id[0] == '\0' ||
            !object_json_int(object_start, object_end, "irrigation_line", &line_number) ||
            line_number <= 0 || line_number > irrigation_line_count ||
            assignments[line_number - 1].assigned ||
            assignment_node_id_seen(assignments, assignment_capacity, assignment.node_id)) {
            memset(assignments, 0, assignment_capacity * sizeof(*assignments));
            *assignment_count_out = 0;
            return VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL;
        }

        (void)object_json_bool(object_start, object_end, "active", &active);
        assignment.assigned = true;
        assignment.active = active;
        assignment.irrigation_line = (uint8_t)line_number;
        assignments[line_number - 1] = assignment;
        (*assignment_count_out)++;
        cursor = object_end + 1;
    }

    *configured_line_count_out = (uint8_t)irrigation_line_count;
    return VG_ACTUATOR_TOPOLOGY_VALID;
}

vg_actuator_topology_result_t vg_actuator_topology_parse_v1(
    const char *payload,
    const char *local_zone_id,
    uint8_t supported_line_count,
    vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    uint8_t *configured_line_count_out,
    size_t *assignment_count_out
) {
    return parse_v1(payload, local_zone_id, true, supported_line_count, assignments,
                    assignment_capacity, configured_line_count_out, assignment_count_out);
}

vg_actuator_topology_result_t vg_actuator_topology_parse_global_v1(
    const char *payload,
    uint8_t supported_line_count,
    vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    uint8_t *configured_line_count_out,
    size_t *assignment_count_out
) {
    return parse_v1(payload, NULL, false, supported_line_count, assignments,
                    assignment_capacity, configured_line_count_out, assignment_count_out);
}

bool vg_actuator_topology_lookup(
    const vg_actuator_topology_assignment_t *assignments,
    size_t assignment_capacity,
    const char *node_id,
    uint8_t *irrigation_line_out
) {
    if (!assignments || !node_id || node_id[0] == '\0' || !irrigation_line_out) {
        return false;
    }

    for (size_t i = 0; i < assignment_capacity; ++i) {
        if (assignments[i].assigned && strcmp(assignments[i].node_id, node_id) == 0) {
            *irrigation_line_out = assignments[i].irrigation_line;
            return true;
        }
    }
    return false;
}
