#include "lora_protocol.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "json_lite.h"

static bool is_mqtt_safe_identifier(const char *value) {
    if (!value || value[0] == '\0') {
        return false;
    }

    for (const char *cursor = value; *cursor != '\0'; cursor++) {
        char ch = *cursor;
        if ((ch >= 'A' && ch <= 'Z') ||
            (ch >= 'a' && ch <= 'z') ||
            (ch >= '0' && ch <= '9') ||
            ch == '.' ||
            ch == '_' ||
            ch == '-') {
            continue;
        }
        return false;
    }

    return true;
}

static const char *skip_json_whitespace_local(const char *cursor) {
    while (*cursor == ' ' || *cursor == '\n' || *cursor == '\r' || *cursor == '\t') {
        cursor++;
    }
    return cursor;
}

static bool is_json_hex_char(char ch) {
    return (ch >= '0' && ch <= '9') ||
           (ch >= 'a' && ch <= 'f') ||
           (ch >= 'A' && ch <= 'F');
}

static bool skip_json_string_local(const char **cursor_in_out) {
    const char *cursor = *cursor_in_out;

    if (*cursor != '"') {
        return false;
    }
    cursor++;

    while (*cursor != '\0') {
        unsigned char ch = (unsigned char)*cursor++;
        if (ch == '"') {
            *cursor_in_out = cursor;
            return true;
        }

        if (ch < 0x20) {
            return false;
        }

        if (ch != '\\') {
            continue;
        }

        ch = (unsigned char)*cursor++;
        switch (ch) {
            case '"':
            case '\\':
            case '/':
            case 'b':
            case 'f':
            case 'n':
            case 'r':
            case 't':
                break;
            case 'u':
                for (int i = 0; i < 4; i++) {
                    if (!is_json_hex_char(*cursor)) {
                        return false;
                    }
                    cursor++;
                }
                break;
            default:
                return false;
        }
    }

    return false;
}

static bool skip_json_container_local(const char **cursor_in_out, char open, char close) {
    const char *cursor = *cursor_in_out;
    int depth = 0;

    if (*cursor != open) {
        return false;
    }

    while (*cursor != '\0') {
        if (*cursor == '"') {
            if (!skip_json_string_local(&cursor)) {
                return false;
            }
            continue;
        }

        if (*cursor == open) {
            depth++;
        } else if (*cursor == close) {
            depth--;
            cursor++;
            if (depth == 0) {
                *cursor_in_out = cursor;
                return true;
            }
            continue;
        }

        cursor++;
    }

    return false;
}

static bool skip_json_value_local(const char **cursor_in_out) {
    const char *cursor = skip_json_whitespace_local(*cursor_in_out);

    if (*cursor == '"') {
        bool ok = skip_json_string_local(&cursor);
        *cursor_in_out = cursor;
        return ok;
    }

    if (*cursor == '{') {
        bool ok = skip_json_container_local(&cursor, '{', '}');
        *cursor_in_out = cursor;
        return ok;
    }

    if (*cursor == '[') {
        bool ok = skip_json_container_local(&cursor, '[', ']');
        *cursor_in_out = cursor;
        return ok;
    }

    if (strncmp(cursor, "true", 4) == 0) {
        *cursor_in_out = cursor + 4;
        return true;
    }

    if (strncmp(cursor, "false", 5) == 0) {
        *cursor_in_out = cursor + 5;
        return true;
    }

    if (strncmp(cursor, "null", 4) == 0) {
        *cursor_in_out = cursor + 4;
        return true;
    }

    if (*cursor == '-' || (*cursor >= '0' && *cursor <= '9')) {
        cursor++;
        while ((*cursor >= '0' && *cursor <= '9') ||
               *cursor == '.' ||
               *cursor == 'e' ||
               *cursor == 'E' ||
               *cursor == '+' ||
               *cursor == '-') {
            cursor++;
        }
        *cursor_in_out = cursor;
        return true;
    }

    return false;
}

static bool is_well_formed_json_object_frame(const char *frame) {
    const char *cursor = skip_json_whitespace_local(frame);

    if (*cursor != '{') {
        return false;
    }
    cursor++;

    cursor = skip_json_whitespace_local(cursor);
    if (*cursor == '}') {
        cursor++;
        return *skip_json_whitespace_local(cursor) == '\0';
    }

    while (*cursor != '\0') {
        cursor = skip_json_whitespace_local(cursor);
        if (!skip_json_string_local(&cursor)) {
            return false;
        }

        cursor = skip_json_whitespace_local(cursor);
        if (*cursor != ':') {
            return false;
        }
        cursor++;

        if (!skip_json_value_local(&cursor)) {
            return false;
        }

        cursor = skip_json_whitespace_local(cursor);
        if (*cursor == ',') {
            cursor++;
            continue;
        }

        if (*cursor == '}') {
            cursor++;
            return *skip_json_whitespace_local(cursor) == '\0';
        }

        return false;
    }

    return false;
}

const char *lora_command_parse_result_name(lora_command_parse_result_t result) {
    switch (result) {
        case LORA_COMMAND_PARSE_REQUEST_READING:
            return "request_reading";
        case LORA_COMMAND_PARSE_MALFORMED:
            return "malformed";
        case LORA_COMMAND_PARSE_MISSING_FIELD:
            return "missing_field";
        case LORA_COMMAND_PARSE_INVALID_IDENTIFIER:
            return "invalid_identifier";
        case LORA_COMMAND_PARSE_INVALID_SEQUENCE:
            return "invalid_sequence";
        case LORA_COMMAND_PARSE_WRONG_SCHEMA:
            return "wrong_schema";
        case LORA_COMMAND_PARSE_WRONG_TARGET:
            return "wrong_target";
        case LORA_COMMAND_PARSE_UNSUPPORTED_COMMAND:
            return "unsupported_command";
    }
    return "unknown";
}

bool lora_node_id_matches_config(const node_config_t *config, const char *node_id) {
    if (!config || !node_id || node_id[0] == '\0') {
        return false;
    }

    if (strcmp(node_id, config->node_id) == 0) {
        return true;
    }

    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        if (strcmp(node_id, config->channel_node_id[channel]) == 0) {
            return true;
        }
    }

    return false;
}

static lora_command_parse_result_t parse_compact_command(
    const node_config_t *config,
    const char *frame,
    lora_command_t *command_out
) {
    char command_code[32] = {0};
    int sequence = 0;

    (void)extract_json_string(
        frame,
        "mid",
        command_out->message_id,
        sizeof(command_out->message_id)
    );
    (void)extract_json_string(
        frame,
        "n",
        command_out->target_node_id,
        sizeof(command_out->target_node_id)
    );
    if (extract_json_int(frame, "sq", &sequence)) {
        if (sequence < 1) {
            return LORA_COMMAND_PARSE_INVALID_SEQUENCE;
        }
        command_out->sequence = sequence;
    }

    if (command_out->message_id[0] == '\0' ||
        command_out->target_node_id[0] == '\0' ||
        !extract_json_string(frame, "c", command_code, sizeof(command_code))) {
        return LORA_COMMAND_PARSE_MISSING_FIELD;
    }

    if (!is_mqtt_safe_identifier(command_out->message_id) ||
        !is_mqtt_safe_identifier(command_out->target_node_id)) {
        return LORA_COMMAND_PARSE_INVALID_IDENTIFIER;
    }

    if (!lora_node_id_matches_config(config, command_out->target_node_id)) {
        return LORA_COMMAND_PARSE_WRONG_TARGET;
    }

    if (strcmp(command_code, VG_LORA_COMPACT_COMMAND_REQUEST_READING) != 0) {
        return LORA_COMMAND_PARSE_UNSUPPORTED_COMMAND;
    }

    return LORA_COMMAND_PARSE_REQUEST_READING;
}

static lora_command_parse_result_t parse_full_command(
    const node_config_t *config,
    const char *frame,
    lora_command_t *command_out
) {
    char schema[32] = {0};
    char command_name[32] = {0};

    (void)extract_json_string(
        frame,
        "message_id",
        command_out->message_id,
        sizeof(command_out->message_id)
    );
    (void)extract_json_string(
        frame,
        "target_node_id",
        command_out->target_node_id,
        sizeof(command_out->target_node_id)
    );

    if (!extract_json_string(frame, "schema_version", schema, sizeof(schema)) ||
        command_out->message_id[0] == '\0' ||
        command_out->target_node_id[0] == '\0' ||
        !extract_json_string(frame, "command", command_name, sizeof(command_name))) {
        return LORA_COMMAND_PARSE_MISSING_FIELD;
    }

    if (!is_mqtt_safe_identifier(command_out->message_id) ||
        !is_mqtt_safe_identifier(command_out->target_node_id)) {
        return LORA_COMMAND_PARSE_INVALID_IDENTIFIER;
    }

    if (strcmp(schema, VG_LORA_COMMAND_SCHEMA_VERSION) != 0) {
        return LORA_COMMAND_PARSE_WRONG_SCHEMA;
    }

    if (!lora_node_id_matches_config(config, command_out->target_node_id)) {
        return LORA_COMMAND_PARSE_WRONG_TARGET;
    }

    if (strcmp(command_name, VG_LORA_COMMAND_REQUEST_READING) != 0) {
        return LORA_COMMAND_PARSE_UNSUPPORTED_COMMAND;
    }

    return LORA_COMMAND_PARSE_REQUEST_READING;
}

lora_command_parse_result_t lora_parse_command_frame(
    const node_config_t *config,
    const char *frame,
    lora_command_t *command_out
) {
    char compact_type[16] = {0};

    if (command_out) {
        memset(command_out, 0, sizeof(*command_out));
    }

    if (!config || !frame || !command_out || !is_well_formed_json_object_frame(frame)) {
        return LORA_COMMAND_PARSE_MALFORMED;
    }

    (void)extract_json_string(frame, "t", compact_type, sizeof(compact_type));
    if (compact_type[0] != '\0') {
        if (strcmp(compact_type, VG_LORA_COMPACT_COMMAND_TYPE) != 0) {
            return LORA_COMMAND_PARSE_WRONG_SCHEMA;
        }
        return parse_compact_command(config, frame, command_out);
    }

    return parse_full_command(config, frame, command_out);
}

static bool format_compact_state_frame(
    char *out,
    size_t out_size,
    const node_config_t *config,
    const sensor_snapshot_t *snapshot,
    const char *node_id,
    const char *correlation_id,
    const char *reason,
    int sequence,
    uint32_t uptime_seconds
) {
    char environment_fields[64] = {0};
    char reason_field[64] = {0};
    char sequence_field[24] = {0};
    int written;

    if (!out ||
        out_size == 0 ||
        !config ||
        !snapshot ||
        !node_id ||
        !correlation_id ||
        !snapshot->soil_moisture_read ||
        !is_mqtt_safe_identifier(config->zone_id) ||
        !is_mqtt_safe_identifier(node_id) ||
        !is_mqtt_safe_identifier(correlation_id) ||
        (reason && !is_mqtt_safe_identifier(reason))) {
        return false;
    }

    if (sequence < 0) {
        return false;
    }

    if (snapshot->environment_valid) {
        snprintf(
            environment_fields,
            sizeof(environment_fields),
            ",\"at\":%.2f,\"h\":%.2f",
            (double)snapshot->air_temperature_c,
            (double)snapshot->humidity_percent
        );
    }

    if (reason && reason[0] != '\0') {
        snprintf(reason_field, sizeof(reason_field), ",\"r\":\"%s\"", reason);
    }

    if (sequence > 0) {
        snprintf(sequence_field, sizeof(sequence_field), ",\"sq\":%d", sequence);
    }

    written = snprintf(
        out,
        out_size,
        "{\"t\":\"state\","
        "\"z\":\"%s\","
        "\"n\":\"%s\","
        "\"mid\":\"%s\","
        "\"mr\":%u,"
        "\"mp\":%d"
        "%s"
        "%s"
        "%s,"
        "\"up\":%lu}\n",
        config->zone_id,
        node_id,
        correlation_id,
        snapshot->moisture_raw,
        snapshot->moisture_percent,
        environment_fields,
        reason_field,
        sequence_field,
        (unsigned long)uptime_seconds
    );

    return written >= 0 && (size_t)written < out_size;
}

bool lora_format_compact_state_frame(
    char *out,
    size_t out_size,
    const node_config_t *config,
    const sensor_snapshot_t *snapshot,
    const char *node_id,
    const char *correlation_id,
    int sequence,
    uint32_t uptime_seconds
) {
    return format_compact_state_frame(
        out,
        out_size,
        config,
        snapshot,
        node_id,
        correlation_id,
        NULL,
        sequence,
        uptime_seconds
    );
}

bool lora_format_compact_channel_state_frame(
    char *out,
    size_t out_size,
    const node_config_t *config,
    const sensor_snapshot_t *snapshot,
    uint8_t channel,
    const char *correlation_id,
    int sequence,
    uint32_t uptime_seconds
) {
    if (!config || channel >= VG_ADS1115_CHANNEL_COUNT) {
        return false;
    }

    return lora_format_compact_state_frame(
        out,
        out_size,
        config,
        snapshot,
        config->channel_node_id[channel],
        correlation_id,
        sequence,
        uptime_seconds
    );
}

int lora_sequence_for_channel(uint32_t wake_count, uint8_t channel) {
    if (channel >= VG_ADS1115_CHANNEL_COUNT) {
        return 0;
    }

    const uint32_t channel_count = VG_ADS1115_CHANNEL_COUNT;
    const uint32_t max_wake_indices = (uint32_t)INT_MAX / channel_count;
    const uint32_t wake_index = wake_count > 0 ? wake_count - 1u : 0u;
    const uint32_t bounded_wake_index = max_wake_indices > 0
        ? wake_index % max_wake_indices
        : 0u;
    const uint32_t sequence = (bounded_wake_index * channel_count) + (uint32_t)channel + 1u;

    return sequence <= (uint32_t)INT_MAX ? (int)sequence : 0;
}

bool lora_format_autonomous_channel_state_frame(
    char *out,
    size_t out_size,
    const node_config_t *config,
    const sensor_snapshot_t *snapshot,
    uint8_t channel,
    const char *reason,
    uint32_t wake_count,
    uint32_t uptime_seconds
) {
    char message_id[VG_LORA_MAX_MESSAGE_ID_LEN] = {0};
    int sequence = lora_sequence_for_channel(wake_count, channel);

    if (!config || channel >= VG_ADS1115_CHANNEL_COUNT || !reason || reason[0] == '\0' || sequence < 1) {
        return false;
    }

    int written = snprintf(
        message_id,
        sizeof(message_id),
        "%s-w%lu-c%u",
        config->channel_node_id[channel],
        (unsigned long)wake_count,
        (unsigned)channel
    );
    if (written < 0 || (size_t)written >= sizeof(message_id)) {
        return false;
    }

    return format_compact_state_frame(
        out,
        out_size,
        config,
        snapshot,
        config->channel_node_id[channel],
        message_id,
        reason,
        sequence,
        uptime_seconds
    );
}
