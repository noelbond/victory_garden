#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "actuator_topology.h"

#define TEST_LINE_CAPACITY 6u

static vg_actuator_topology_result_t parse(
    const char *payload,
    vg_actuator_topology_assignment_t *assignments,
    uint8_t *configured_line_count,
    size_t *assignment_count
) {
    return vg_actuator_topology_parse_v1(
        payload, "zone1", TEST_LINE_CAPACITY, assignments, TEST_LINE_CAPACITY,
        configured_line_count, assignment_count
    );
}

static vg_actuator_topology_result_t parse_global(
    const char *payload,
    vg_actuator_topology_assignment_t *assignments,
    uint8_t *configured_line_count,
    size_t *assignment_count
) {
    return vg_actuator_topology_parse_global_v1(
        payload, TEST_LINE_CAPACITY, assignments, TEST_LINE_CAPACITY,
        configured_line_count, assignment_count
    );
}

static char *read_fixture(void) {
    FILE *file = fopen(VG_FIRMWARE_SAFE_IDENTITY_FIXTURE, "rb");
    assert(file != NULL);
    assert(fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file);
    assert(length > 0);
    rewind(file);

    char *payload = calloc((size_t)length + 1u, 1u);
    assert(payload != NULL);
    assert(fread(payload, 1, (size_t)length, file) == (size_t)length);
    assert(fclose(file) == 0);
    return payload;
}

static void test_firmware_safe_identity_fixture_round_trips_through_topology_parser(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    char *payload = read_fixture();

    assert(parse_global(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(line_count == 1);
    assert(assignment_count == 1);
    assert(strcmp(assignments[0].zone_id, "Zz09-_") == 0);
    assert(strcmp(assignments[0].node_id, "Az09-_-ch0") == 0);

    free(payload);
}

static void test_local_line_isolated_from_foreign_reuse(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":4,\"nodes\":["
        "{\"node_id\":\"local\",\"zone_id\":\"zone1\",\"irrigation_line\":1},"
        "{\"node_id\":\"foreign\",\"zone_id\":\"zone2\",\"irrigation_line\":1}]}";

    assert(parse(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(line_count == 4);
    assert(assignment_count == 1);
    assert(strcmp(assignments[0].node_id, "local") == 0);
}

static void test_duplicate_local_line_is_invalid(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":4,\"nodes\":["
        "{\"node_id\":\"one\",\"zone_id\":\"zone1\",\"irrigation_line\":1},"
        "{\"node_id\":\"two\",\"zone_id\":\"zone1\",\"irrigation_line\":1}]}";

    assert(parse(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL);
    assert(assignment_count == 0);
    assert(!assignments[0].assigned);
}

static void test_duplicate_local_node_is_invalid(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":4,\"nodes\":["
        "{\"node_id\":\"same\",\"zone_id\":\"zone1\",\"irrigation_line\":1},"
        "{\"node_id\":\"same\",\"zone_id\":\"zone1\",\"irrigation_line\":2}]}";

    assert(parse(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL);
    assert(!assignments[0].assigned);
    assert(!assignments[1].assigned);
}

static void test_invalid_local_line_is_invalid(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":2,\"nodes\":["
        "{\"node_id\":\"local\",\"zone_id\":\"zone1\",\"irrigation_line\":3}]}";

    assert(parse(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL);
    assert(!assignments[0].assigned);
}

static void test_configured_count_cannot_exceed_supported_outputs(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":7,\"nodes\":[]}";

    assert(parse(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_CONFIG);
    assert(line_count == 0);
    assert(assignment_count == 0);
}

static void test_malformed_foreign_entry_is_ignored(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":4,\"nodes\":["
        "{\"node_id\":\"local\",\"zone_id\":\"zone1\",\"irrigation_line\":2},"
        "{\"zone_id\":\"zone2\",\"irrigation_line\":1}]}";

    assert(parse(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(assignment_count == 1);
    assert(strcmp(assignments[1].node_id, "local") == 0);
}

static void test_zero_local_nodes_and_zones_only_are_valid(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *foreign_only =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":4,\"nodes\":["
        "{\"node_id\":\"foreign\",\"zone_id\":\"zone2\",\"irrigation_line\":1}]}";
    const char *zones_only =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":4,\"zones\":["
        "{\"zone_id\":\"zone1\",\"irrigation_line\":1}]}";

    assert(parse(foreign_only, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(line_count == 4);
    assert(assignment_count == 0);
    assert(!vg_actuator_topology_lookup(assignments, TEST_LINE_CAPACITY, "foreign", &line_count));

    assert(parse(zones_only, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(assignment_count == 0);
    assert(!vg_actuator_topology_lookup(assignments, TEST_LINE_CAPACITY, "anything", &line_count));
}

static void test_lookup_and_multiple_local_nodes(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    uint8_t irrigation_line = 0;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":4,\"nodes\":["
        "{\"node_id\":\"one\",\"zone_id\":\"zone1\",\"irrigation_line\":1},"
        "{\"node_id\":\"four\",\"zone_id\":\"zone1\",\"irrigation_line\":4}]}";

    assert(parse(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(assignment_count == 2);
    assert(vg_actuator_topology_lookup(assignments, TEST_LINE_CAPACITY, "one", &irrigation_line));
    assert(irrigation_line == 1);
    assert(vg_actuator_topology_lookup(assignments, TEST_LINE_CAPACITY, "four", &irrigation_line));
    assert(irrigation_line == 4);
    assert(!vg_actuator_topology_lookup(assignments, TEST_LINE_CAPACITY, "unknown", &irrigation_line));
}

static void test_global_topology_accepts_nodes_from_multiple_zones(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":5,\"nodes\":["
        "{\"node_id\":\"zone-a-node\",\"zone_id\":\"zone-a\",\"irrigation_line\":1},"
        "{\"node_id\":\"zone-b-node\",\"zone_id\":\"zone-b\",\"irrigation_line\":5}]}";

    assert(parse_global(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(line_count == 5);
    assert(assignment_count == 2);
    assert(strcmp(assignments[0].zone_id, "zone-a") == 0);
    assert(strcmp(assignments[4].zone_id, "zone-b") == 0);
}

static void test_global_duplicate_line_across_zones_is_invalid(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":5,\"nodes\":["
        "{\"node_id\":\"zone-a-node\",\"zone_id\":\"zone-a\",\"irrigation_line\":1},"
        "{\"node_id\":\"zone-b-node\",\"zone_id\":\"zone-b\",\"irrigation_line\":1}]}";

    assert(parse_global(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL);
    assert(assignment_count == 0);
    assert(!assignments[0].assigned);
}

static void test_global_duplicate_node_or_missing_zone_is_invalid(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *duplicate_node =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":5,\"nodes\":["
        "{\"node_id\":\"same-node\",\"zone_id\":\"zone-a\",\"irrigation_line\":1},"
        "{\"node_id\":\"same-node\",\"zone_id\":\"zone-b\",\"irrigation_line\":2}]}";
    const char *missing_zone =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":5,\"nodes\":["
        "{\"node_id\":\"node\",\"irrigation_line\":1}]}";

    assert(parse_global(duplicate_node, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL);
    assert(parse_global(missing_zone, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL);
}

static void test_global_empty_topology_is_valid(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    const char *payload =
        "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":0,\"nodes\":[]}";

    assert(parse_global(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_VALID);
    assert(line_count == 0);
    assert(assignment_count == 0);
}

static void test_global_overlong_zone_or_node_identity_is_invalid(void) {
    vg_actuator_topology_assignment_t assignments[TEST_LINE_CAPACITY];
    uint8_t line_count;
    size_t assignment_count;
    char overlong[33];
    char payload[512];
    memset(overlong, 'x', 32);
    overlong[32] = '\0';

    snprintf(payload, sizeof(payload),
             "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":1,\"nodes\":["
             "{\"node_id\":\"node\",\"zone_id\":\"%s\",\"irrigation_line\":1}]}", overlong);
    assert(parse_global(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL);
    assert(assignment_count == 0);
    assert(!assignments[0].assigned);

    snprintf(payload, sizeof(payload),
             "{\"schema_version\":\"actuator-config/v1\",\"irrigation_line_count\":1,\"nodes\":["
             "{\"node_id\":\"%s\",\"zone_id\":\"zone\",\"irrigation_line\":1}]}", overlong);
    assert(parse_global(payload, assignments, &line_count, &assignment_count) == VG_ACTUATOR_TOPOLOGY_INVALID_LOCAL);
    assert(assignment_count == 0);
    assert(!assignments[0].assigned);
}

int main(void) {
    test_firmware_safe_identity_fixture_round_trips_through_topology_parser();
    test_local_line_isolated_from_foreign_reuse();
    test_duplicate_local_line_is_invalid();
    test_duplicate_local_node_is_invalid();
    test_invalid_local_line_is_invalid();
    test_configured_count_cannot_exceed_supported_outputs();
    test_malformed_foreign_entry_is_ignored();
    test_zero_local_nodes_and_zones_only_are_valid();
    test_lookup_and_multiple_local_nodes();
    test_global_topology_accepts_nodes_from_multiple_zones();
    test_global_duplicate_line_across_zones_is_invalid();
    test_global_duplicate_node_or_missing_zone_is_invalid();
    test_global_empty_topology_is_valid();
    test_global_overlong_zone_or_node_identity_is_invalid();
    puts("actuator_topology_tests: passed");
    return 0;
}
