#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "config.h"

#if VG_ENABLE_LORA_TRANSPORT

#include "lora_protocol.h"
#include "lora_transport.h"

static const uint32_t VG_LORA_COMMAND_WINDOW_MS = 100u;
static const uint32_t VG_LORA_COMMAND_INTAKE_WINDOW_MS = 7000u;
static const uint32_t VG_LORA_POST_TELEMETRY_COMMAND_WINDOW_MS = 15000u;

typedef struct {
    uint16_t frames;
    uint16_t valid_commands;
    uint16_t queued_commands;
    uint16_t duplicate_commands;
    uint16_t dropped_commands;
    uint16_t executed_commands;
    uint16_t command_failures;
    uint16_t malformed_frames;
    uint16_t wrong_target_frames;
    uint16_t oversized_frames;
    uint16_t ignored_frames;
} lora_command_window_stats_t;

typedef enum {
    LORA_PENDING_COMMAND_NONE,
    LORA_PENDING_COMMAND_REQUEST_READING,
} lora_pending_command_type_t;

typedef struct {
    lora_pending_command_type_t type;
    lora_command_t command;
} lora_pending_command_t;

typedef struct {
    bool valid;
    lora_command_t command;
} lora_recent_command_t;

void service_lora_command_window(
    lora_transport_t *transport,
    lora_frame_buffer_t *buffer,
    const node_config_t *config,
    uint32_t timeout_ms,
    lora_pending_command_t *pending,
    const lora_recent_command_t *recent_commands,
    size_t recent_command_count,
    lora_command_window_stats_t *stats
);

void handle_pending_lora_command(
    lora_transport_t *transport,
    const node_config_t *config,
    lora_pending_command_t *pending,
    lora_recent_command_t *recent_commands,
    size_t recent_command_count,
    size_t *next_recent_command,
    float air_temperature_c,
    float humidity_percent,
    bool environment_valid,
    bool *soil_sensors_initialized,
    lora_command_window_stats_t *stats
);

void service_lora_command_window_and_handle(
    lora_transport_t *transport,
    lora_frame_buffer_t *buffer,
    const node_config_t *config,
    uint32_t timeout_ms,
    lora_pending_command_t *pending,
    lora_recent_command_t *recent_commands,
    size_t recent_command_count,
    size_t *next_recent_command,
    float air_temperature_c,
    float humidity_percent,
    bool environment_valid,
    bool *soil_sensors_initialized,
    lora_command_window_stats_t *stats
);

void log_lora_command_window_summary(const lora_command_window_stats_t *stats);

#endif
