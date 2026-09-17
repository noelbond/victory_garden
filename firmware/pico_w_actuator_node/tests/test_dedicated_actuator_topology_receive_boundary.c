#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "actuator_command_guard.h"
#include "actuator_topology.h"
#include "dedicated_actuator_topology_receive.h"
#include "json_lite.h"

static void appendf(char *buffer, size_t capacity, size_t *length, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int written = vsnprintf(buffer + *length, capacity - *length, format, args);
    va_end(args);
    assert(written >= 0);
    assert((size_t)written < capacity - *length);
    *length += (size_t)written;
}

static void append_max_safe_identity(
    char *buffer, size_t capacity, size_t *length, size_t count, unsigned identity_variant
) {
    static const char safe_alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    for (size_t index = 0; index < count; ++index) {
        // The Rails producer accepts only [A-Za-z0-9_-]. Vary the final byte
        // so the three maximum-length packages and Zones remain distinct.
        const char character = index + 1u == count
            ? (char)('0' + identity_variant)
            : safe_alphabet[index % (sizeof(safe_alphabet) - 1u)];
        appendf(buffer, capacity, length, "%c", character);
    }
}

static size_t build_largest_legal_topology(char *payload, size_t capacity) {
    size_t length = 0;
    appendf(payload, capacity, &length,
            "{\"schema_version\":\"actuator-config/v1\","
            "\"config_version\":\"2026-09-17T00:00:00Z\","
            "\"irrigation_line_count\":12,\"zones\":[],\"nodes\":[");

    for (unsigned line = 1; line <= 12; ++line) {
        unsigned package_variant = (line - 1u) / 4u;
        if (line > 1) {
            appendf(payload, capacity, &length, ",");
        }
        appendf(payload, capacity, &length, "{\"node_id\":\"");
        append_max_safe_identity(payload, capacity, &length, 27, package_variant);
        appendf(payload, capacity, &length, "-ch%u\",\"zone_id\":\"", (line - 1u) % 4u);
        append_max_safe_identity(payload, capacity, &length, 31, package_variant);
        appendf(payload, capacity, &length,
                "\",\"irrigation_line\":%u,\"active\":true}", line);
    }
    appendf(payload, capacity, &length, "]}");
    return length;
}

static char *read_source(void) {
    FILE *file = fopen(VG_DEDICATED_MQTT_SOURCE, "rb");
    assert(file != NULL);
    assert(fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file);
    assert(length > 0);
    rewind(file);

    char *source = calloc((size_t)length + 1u, 1u);
    assert(source != NULL);
    assert(fread(source, 1, (size_t)length, file) == (size_t)length);
    assert(fclose(file) == 0);
    return source;
}

static void test_largest_legal_topology_has_documented_receive_margin(void) {
    char payload[VG_DEDICATED_ACTUATOR_MQTT_RX_PAYLOAD_STORAGE_BYTES] = {0};
    vg_actuator_topology_assignment_t assignments[12] = {0};
    uint8_t irrigation_line_count = 0;
    size_t assignment_count = 0;
    size_t length = build_largest_legal_topology(payload, sizeof(payload));

    assert(length == VG_DEDICATED_ACTUATOR_TOPOLOGY_LEGAL_MAX_SERIALIZED_BYTES);
    assert(length < VG_DEDICATED_ACTUATOR_MQTT_RX_PAYLOAD_STORAGE_BYTES);
    assert(VG_DEDICATED_ACTUATOR_MQTT_RX_MAX_PAYLOAD_BYTES - length == 2477u);
    assert(vg_actuator_topology_parse_global_v1(
        payload, 12, assignments, 12, &irrigation_line_count, &assignment_count
    ) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(irrigation_line_count == 12);
    assert(assignment_count == 12);

    while (length < VG_DEDICATED_ACTUATOR_MQTT_RX_MAX_PAYLOAD_BYTES) {
        payload[length++] = ' ';
    }
    payload[length] = '\0';
    assert(length == VG_DEDICATED_ACTUATOR_MQTT_RX_MAX_PAYLOAD_BYTES);
    assert(vg_actuator_topology_parse_global_v1(
        payload, 12, assignments, 12, &irrigation_line_count, &assignment_count
    ) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(assignment_count == 12);
    assert(length + 1u > VG_DEDICATED_ACTUATOR_MQTT_RX_MAX_PAYLOAD_BYTES);
}

static void test_one_byte_over_receive_limit_uses_fail_closed_topology_path(void) {
    char *source = read_source();
    const char *helper = strstr(source, "static void fail_closed_retained_topology_receive");
    const char *stop = helper ? strstr(helper, "stop_runs_invalidated_by_topology(node, NULL, 0);") : NULL;
    const char *clear = stop ? strstr(stop, "clear_actuator_topology(node);") : NULL;
    const char *helper_end = helper ? strstr(helper, "\n}\n\nstatic void handle_actuator_config_message") : NULL;
    const char *journal_mutation = helper ? strstr(helper, "vg_dedicated_actuator_journal") : NULL;
    const char *handler = strstr(source, "static void handle_actuator_config_message");
    const char *parsed_invalid = handler ? strstr(handler, "fail_closed_retained_topology_receive(node, \"invalid actuator config\")") : NULL;
    const char *publish = strstr(source, "static void mqtt_incoming_publish_cb");
    const char *announced_limit = publish ? strstr(publish, "tot_len > VG_DEDICATED_ACTUATOR_MQTT_RX_MAX_PAYLOAD_BYTES") : NULL;
    const char *announced_failure = announced_limit ? strstr(announced_limit, "fail_closed_retained_topology_receive(node, \"actuator config payload too large\")") : NULL;
    const char *data = strstr(source, "static void mqtt_incoming_data_cb");
    const char *streaming_limit = data ? strstr(data, "g_runtime.incoming_payload_len + len > VG_DEDICATED_ACTUATOR_MQTT_RX_MAX_PAYLOAD_BYTES") : NULL;
    const char *streaming_failure = streaming_limit ? strstr(streaming_limit, "fail_closed_retained_topology_receive(node, \"actuator config payload too large\")") : NULL;

    assert(helper != NULL && helper_end != NULL && stop != NULL && clear != NULL);
    assert(stop < clear);
    assert(journal_mutation == NULL || journal_mutation > helper_end);
    assert(parsed_invalid != NULL);
    assert(announced_limit != NULL && announced_failure != NULL);
    assert(streaming_limit != NULL && streaming_failure != NULL);

    free(source);
}

static void test_overlong_dedicated_command_identity_cannot_match_prefix(void) {
    char valid_node_id[32];
    char overlong_node_id[36];
    char payload[256];
    char payload_zone_id[32] = {0};
    char payload_node_id[32] = {0};
    memset(valid_node_id, 'n', 31);
    valid_node_id[31] = '\0';
    memcpy(overlong_node_id, valid_node_id, 31);
    memcpy(overlong_node_id + 31, "more", 5);

    const int written = snprintf(
        payload, sizeof(payload),
        "{\"zone_id\":\"zone-a\",\"node_id\":\"%s\"}", overlong_node_id
    );
    assert(written > 0 && (size_t)written < sizeof(payload));
    assert(extract_json_string(payload, "zone_id", payload_zone_id, sizeof(payload_zone_id)));
    assert(!extract_json_string(payload, "node_id", payload_node_id, sizeof(payload_node_id)));
    assert(payload_node_id[0] == '\0');
    assert(vg_actuator_command_guard_validate_global(
        "zone-a", payload_zone_id, true, payload_node_id
    ) == VG_ACTUATOR_COMMAND_GUARD_MISSING_NODE);
    assert(strcmp(payload_node_id, valid_node_id) != 0);
}

int main(void) {
    test_largest_legal_topology_has_documented_receive_margin();
    test_one_byte_over_receive_limit_uses_fail_closed_topology_path();
    test_overlong_dedicated_command_identity_cannot_match_prefix();
    puts("dedicated_actuator_topology_receive_boundary_tests: passed");
    return 0;
}
