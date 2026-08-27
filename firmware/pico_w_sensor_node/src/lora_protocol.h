#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "config.h"
#include "sensors.h"

#define VG_LORA_COMMAND_SCHEMA_VERSION "lora-command/v1"
#define VG_LORA_COMMAND_REQUEST_READING "request_reading"
#define VG_LORA_COMPACT_COMMAND_TYPE "cmd"
#define VG_LORA_COMPACT_COMMAND_REQUEST_READING "rr"
#define VG_LORA_MAX_MESSAGE_ID_LEN 128u

typedef enum {
    LORA_COMMAND_PARSE_REQUEST_READING,
    LORA_COMMAND_PARSE_MALFORMED,
    LORA_COMMAND_PARSE_MISSING_FIELD,
    LORA_COMMAND_PARSE_INVALID_IDENTIFIER,
    LORA_COMMAND_PARSE_INVALID_SEQUENCE,
    LORA_COMMAND_PARSE_WRONG_SCHEMA,
    LORA_COMMAND_PARSE_WRONG_TARGET,
    LORA_COMMAND_PARSE_UNSUPPORTED_COMMAND,
} lora_command_parse_result_t;

typedef struct {
    char message_id[VG_LORA_MAX_MESSAGE_ID_LEN];
    char target_node_id[VG_MAX_NODE_ID_LEN];
    int sequence;
} lora_command_t;

const char *lora_command_parse_result_name(lora_command_parse_result_t result);
bool lora_node_id_matches_config(const node_config_t *config, const char *node_id);
lora_command_parse_result_t lora_parse_command_frame(
    const node_config_t *config,
    const char *frame,
    lora_command_t *command_out
);
bool lora_format_compact_state_frame(
    char *out,
    size_t out_size,
    const node_config_t *config,
    const sensor_snapshot_t *snapshot,
    const char *node_id,
    const char *correlation_id,
    int sequence,
    uint32_t uptime_seconds
);
bool lora_format_compact_channel_state_frame(
    char *out,
    size_t out_size,
    const node_config_t *config,
    const sensor_snapshot_t *snapshot,
    uint8_t channel,
    const char *correlation_id,
    int sequence,
    uint32_t uptime_seconds
);
int lora_sequence_for_channel(uint32_t wake_count, uint8_t channel);
bool lora_format_autonomous_channel_state_frame(
    char *out,
    size_t out_size,
    const node_config_t *config,
    const sensor_snapshot_t *snapshot,
    uint8_t channel,
    const char *reason,
    uint32_t wake_count,
    uint32_t uptime_seconds
);
