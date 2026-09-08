#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "lora_protocol.h"

static node_config_t test_config(void) {
    node_config_t config = {0};
    strcpy(config.node_id, "sensor-zone1-device");
    strcpy(config.zone_id, "zone1");
    strcpy(config.channel_node_id[0], "sensor-zone1-ch0");
    strcpy(config.channel_node_id[2], "sensor-zone1-ch2");
    return config;
}

static void test_channel_target_is_accepted(void) {
    const node_config_t config = test_config();
    lora_command_t command;
    const lora_command_parse_result_t result = lora_parse_command_frame(
        &config,
        "{\"t\":\"cmd\",\"c\":\"rr\",\"n\":\"sensor-zone1-ch2\",\"mid\":\"pi-123\",\"sq\":7}",
        &command
    );

    assert(result == LORA_COMMAND_PARSE_REQUEST_READING);
    assert(strcmp(command.target_node_id, "sensor-zone1-ch2") == 0);
    assert(strcmp(command.message_id, "pi-123") == 0);
    assert(command.sequence == 7);
}

static void test_target_filtering_and_unsupported_commands(void) {
    const node_config_t config = test_config();
    lora_command_t command;

    assert(lora_parse_command_frame(
        &config,
        "{\"t\":\"cmd\",\"c\":\"rr\",\"n\":\"other-node\",\"mid\":\"pi-123\"}",
        &command
    ) == LORA_COMMAND_PARSE_WRONG_TARGET);

    // The physical id reaches runtime dispatch, where the existing
    // channel-only executor returns not_channel_node instead of broadening the
    // command into an all-channel read.
    assert(lora_parse_command_frame(
        &config,
        "{\"t\":\"cmd\",\"c\":\"rr\",\"n\":\"sensor-zone1-device\",\"mid\":\"pi-123\"}",
        &command
    ) == LORA_COMMAND_PARSE_REQUEST_READING);

    assert(lora_parse_command_frame(
        &config,
        "{\"t\":\"cmd\",\"c\":\"all\",\"n\":\"sensor-zone1-ch0\",\"mid\":\"pi-123\"}",
        &command
    ) == LORA_COMMAND_PARSE_UNSUPPORTED_COMMAND);

    assert(lora_parse_command_frame(&config, "{\"t\":", &command) == LORA_COMMAND_PARSE_MALFORMED);
}

static void test_environment_fields_require_current_validity(void) {
    const node_config_t config = test_config();
    sensor_snapshot_t snapshot = {
        .moisture_raw = 2200u,
        .moisture_percent = 45,
        .air_temperature_c = 23.5f,
        .humidity_percent = 58.0f,
        .soil_moisture_read = true,
    };
    char frame[VG_LORA_MAX_FRAME_SIZE + 1u];

    snapshot.environment_valid = false;
    assert(lora_format_compact_channel_state_frame(
        frame, sizeof(frame), &config, &snapshot, 0u, "pi-123", 1, 42u
    ));
    assert(strstr(frame, "\"at\":") == NULL);
    assert(strstr(frame, "\"h\":") == NULL);

    snapshot.environment_valid = true;
    assert(lora_format_compact_channel_state_frame(
        frame, sizeof(frame), &config, &snapshot, 0u, "pi-123", 1, 42u
    ));
    assert(strstr(frame, "\"at\":23.50") != NULL);
    assert(strstr(frame, "\"h\":58.00") != NULL);
}

int main(void) {
    test_channel_target_is_accepted();
    test_target_filtering_and_unsupported_commands();
    test_environment_fields_require_current_validity();
    puts("lora_protocol_tests: passed");
    return 0;
}
