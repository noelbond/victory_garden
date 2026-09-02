#include "lora_command_runtime.h"

#if VG_ENABLE_LORA_TRANSPORT

#include <stdio.h>
#include <string.h>

#include "hardware/uart.h"
#include "hardware/watchdog.h"
#include "pico/stdlib.h"
#include "sensors.h"
#include "time_sync.h"

typedef enum {
    LORA_QUEUE_RESULT_QUEUED,
    LORA_QUEUE_RESULT_DUPLICATE_PENDING,
    LORA_QUEUE_RESULT_DUPLICATE_COMPLETED,
    LORA_QUEUE_RESULT_DROPPED_PENDING_COMMAND,
} lora_queue_result_t;

static void lora_record_parse_result(lora_command_window_stats_t *stats, lora_command_parse_result_t result) {
    if (!stats) {
        return;
    }

    switch (result) {
        case LORA_COMMAND_PARSE_REQUEST_READING:
            stats->valid_commands++;
            break;
        case LORA_COMMAND_PARSE_MALFORMED:
            stats->malformed_frames++;
            break;
        case LORA_COMMAND_PARSE_WRONG_TARGET:
            stats->wrong_target_frames++;
            break;
        case LORA_COMMAND_PARSE_MISSING_FIELD:
        case LORA_COMMAND_PARSE_INVALID_IDENTIFIER:
        case LORA_COMMAND_PARSE_INVALID_SEQUENCE:
        case LORA_COMMAND_PARSE_WRONG_SCHEMA:
        case LORA_COMMAND_PARSE_UNSUPPORTED_COMMAND:
            stats->ignored_frames++;
            break;
    }
}

static bool lora_command_window_had_activity(const lora_command_window_stats_t *stats) {
    return stats &&
        (stats->frames > 0u ||
         stats->valid_commands > 0u ||
         stats->queued_commands > 0u ||
         stats->duplicate_commands > 0u ||
         stats->dropped_commands > 0u ||
         stats->executed_commands > 0u ||
         stats->command_failures > 0u ||
         stats->malformed_frames > 0u ||
         stats->wrong_target_frames > 0u ||
         stats->oversized_frames > 0u ||
         stats->ignored_frames > 0u);
}

static bool lora_commands_match(const lora_command_t *left, const lora_command_t *right) {
    return left &&
        right &&
        left->sequence == right->sequence &&
        strcmp(left->message_id, right->message_id) == 0 &&
        strcmp(left->target_node_id, right->target_node_id) == 0;
}

static bool lora_recent_command_seen(
    const lora_recent_command_t *recent_commands,
    size_t recent_command_count,
    const lora_command_t *command
) {
    if (!recent_commands || !command) {
        return false;
    }

    for (size_t i = 0; i < recent_command_count; ++i) {
        if (recent_commands[i].valid && lora_commands_match(&recent_commands[i].command, command)) {
            return true;
        }
    }

    return false;
}

static void lora_remember_recent_command(
    lora_recent_command_t *recent_commands,
    size_t recent_command_count,
    size_t *next_recent_command,
    const lora_command_t *command
) {
    if (!recent_commands || recent_command_count == 0u || !next_recent_command || !command) {
        return;
    }

    size_t slot = *next_recent_command % recent_command_count;
    recent_commands[slot].valid = true;
    recent_commands[slot].command = *command;
    *next_recent_command = (slot + 1u) % recent_command_count;
}

static const char *lora_queue_result_name(lora_queue_result_t result) {
    switch (result) {
        case LORA_QUEUE_RESULT_QUEUED:
            return "queued";
        case LORA_QUEUE_RESULT_DUPLICATE_PENDING:
            return "duplicate_pending";
        case LORA_QUEUE_RESULT_DUPLICATE_COMPLETED:
            return "duplicate_completed";
        case LORA_QUEUE_RESULT_DROPPED_PENDING_COMMAND:
            return "dropped_pending_command";
    }
    return "unknown";
}

static lora_queue_result_t lora_queue_request_reading_command(
    lora_pending_command_t *pending,
    const lora_command_t *command,
    const lora_recent_command_t *recent_commands,
    size_t recent_command_count,
    lora_command_window_stats_t *stats
) {
    if (!pending || !command) {
        return LORA_QUEUE_RESULT_DROPPED_PENDING_COMMAND;
    }

    if (pending->type == LORA_PENDING_COMMAND_REQUEST_READING &&
        lora_commands_match(&pending->command, command)) {
        if (stats) {
            stats->duplicate_commands++;
        }
        return LORA_QUEUE_RESULT_DUPLICATE_PENDING;
    }

    if (lora_recent_command_seen(recent_commands, recent_command_count, command)) {
        if (stats) {
            stats->duplicate_commands++;
        }
        return LORA_QUEUE_RESULT_DUPLICATE_COMPLETED;
    }

    if (pending->type != LORA_PENDING_COMMAND_NONE) {
        if (stats) {
            stats->dropped_commands++;
        }
        return LORA_QUEUE_RESULT_DROPPED_PENDING_COMMAND;
    }

    pending->type = LORA_PENDING_COMMAND_REQUEST_READING;
    pending->command = *command;
    if (stats) {
        stats->queued_commands++;
    }
    return LORA_QUEUE_RESULT_QUEUED;
}

static void lora_queue_parsed_request_reading_command(
    const lora_command_t *command,
    lora_pending_command_t *pending,
    const lora_recent_command_t *recent_commands,
    size_t recent_command_count,
    lora_command_window_stats_t *stats
) {
    if (!command) {
        return;
    }

    lora_queue_result_t queue_result =
        lora_queue_request_reading_command(pending, command, recent_commands, recent_command_count, stats);
    printf("[lora] command received type=request_reading target=%s mid=%s sq=%d action=%s\n",
        command->target_node_id,
        command->message_id,
        command->sequence,
        lora_queue_result_name(queue_result));
    stdio_flush();
}

static bool lora_channel_for_target(const node_config_t *config, const char *target_node_id, uint8_t *channel_out) {
    if (!config || !target_node_id || !channel_out) {
        return false;
    }

    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        if (strcmp(target_node_id, config->channel_node_id[channel]) == 0) {
            *channel_out = channel;
            return true;
        }
    }

    return false;
}

static bool lora_send_request_reading_result(
    lora_transport_t *transport,
    const node_config_t *config,
    const lora_command_t *command,
    float air_temperature_c,
    float humidity_percent,
    bool environment_valid,
    bool *soil_sensors_initialized,
    const char **failure_error_out,
    const char **ack_source_node_id_out
) {
    if (failure_error_out) {
        *failure_error_out = "request_reading_failed";
    }
    if (ack_source_node_id_out) {
        *ack_source_node_id_out = config ? config->node_id : NULL;
    }

    if (!transport || !transport->initialized || !config || !command || !soil_sensors_initialized) {
        return false;
    }

    uint8_t channel = 0;
    if (!lora_channel_for_target(config, command->target_node_id, &channel)) {
        if (failure_error_out) {
            *failure_error_out = "not_channel_node";
        }
        printf("[lora] request_reading unsupported target=%s mid=%s reason=not_channel_node\n",
            command->target_node_id,
            command->message_id);
        stdio_flush();
        return false;
    }
    if (ack_source_node_id_out) {
        *ack_source_node_id_out = config->channel_node_id[channel];
    }

    if (!*soil_sensors_initialized) {
        sensors_init(config);
        *soil_sensors_initialized = true;
    }

    sensor_snapshot_t snapshot = {0};
    snapshot.air_temperature_c = air_temperature_c;
    snapshot.humidity_percent = humidity_percent;
    snapshot.environment_valid = environment_valid;
    snapshot.healthy = environment_valid;

    snapshot.soil_moisture_read = sensors_read(config, channel, &snapshot);
    if (!snapshot.soil_moisture_read) {
        if (failure_error_out) {
            *failure_error_out = "sensor_read_failed";
        }
        printf("[lora] request_reading sensor read failed target=%s channel=%u mid=%s\n",
            command->target_node_id,
            (unsigned)channel,
            command->message_id);
        stdio_flush();
        return false;
    }

    char frame[VG_LORA_MAX_FRAME_SIZE + 1u] = {0};
    if (!lora_format_compact_channel_state_frame(
            frame,
            sizeof(frame),
            config,
            &snapshot,
            channel,
            command->message_id,
            command->sequence,
            (uint32_t)(to_ms_since_boot(get_absolute_time()) / 1000u))) {
        if (failure_error_out) {
            *failure_error_out = "state_format_failed";
        }
        printf("[lora] request_reading format failed target=%s channel=%u mid=%s\n",
            command->target_node_id,
            (unsigned)channel,
            command->message_id);
        stdio_flush();
        return false;
    }

    if (!lora_transport_send_frame(transport, "\n", 1u)) {
        if (failure_error_out) {
            *failure_error_out = "lora_warmup_send_failed";
        }
        printf("[lora] request_reading warm-up send failed target=%s channel=%u mid=%s\n",
            command->target_node_id,
            (unsigned)channel,
            command->message_id);
        stdio_flush();
        return false;
    }
    sleep_ms(100);

    if (!lora_transport_send_frame(transport, frame, strlen(frame))) {
        if (failure_error_out) {
            *failure_error_out = "lora_response_send_failed";
        }
        printf("[lora] request_reading response send failed target=%s channel=%u mid=%s\n",
            command->target_node_id,
            (unsigned)channel,
            command->message_id);
        stdio_flush();
        return false;
    }

    printf("[lora] request_reading response sent target=%s channel=%u mid=%s bytes=%u\n",
        command->target_node_id,
        (unsigned)channel,
        command->message_id,
        (unsigned)strlen(frame));
    stdio_flush();
    return true;
}

static bool lora_send_command_failure_ack(
    lora_transport_t *transport,
    const node_config_t *config,
    const lora_command_t *command,
    const char *source_node_id,
    const char *error
) {
    if (!transport || !transport->initialized || !config || !command || !source_node_id || !error) {
        return false;
    }

    char timestamp[32] = {0};
    char frame[VG_LORA_MAX_FRAME_SIZE + 1u] = {0};
    time_sync_format_iso8601(timestamp, sizeof(timestamp));
    if (!lora_format_command_ack_frame(
            frame,
            sizeof(frame),
            config,
            source_node_id,
            command,
            timestamp,
            "failed",
            error)) {
        printf("[lora] command failure ack format failed source=%s mid=%s error=%s\n",
            source_node_id,
            command->message_id,
            error);
        stdio_flush();
        return false;
    }

    if (!lora_transport_send_frame(transport, "\n", 1u)) {
        printf("[lora] command failure ack warm-up send failed source=%s mid=%s error=%s\n",
            source_node_id,
            command->message_id,
            error);
        stdio_flush();
        return false;
    }
    sleep_ms(100);

    if (!lora_transport_send_frame(transport, frame, strlen(frame))) {
        printf("[lora] command failure ack send failed source=%s mid=%s error=%s\n",
            source_node_id,
            command->message_id,
            error);
        stdio_flush();
        return false;
    }

    printf("[lora] command failure ack sent source=%s mid=%s error=%s bytes=%u\n",
        source_node_id,
        command->message_id,
        error,
        (unsigned)strlen(frame));
    stdio_flush();
    return true;
}

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
) {
    if (!pending || pending->type == LORA_PENDING_COMMAND_NONE) {
        return;
    }

    bool handled = false;
    const char *failure_error = NULL;
    const char *ack_source_node_id = NULL;
    switch (pending->type) {
        case LORA_PENDING_COMMAND_REQUEST_READING:
            handled = lora_send_request_reading_result(
                transport,
                config,
                &pending->command,
                air_temperature_c,
                humidity_percent,
                environment_valid,
                soil_sensors_initialized,
                &failure_error,
                &ack_source_node_id
            );
            if (!handled && failure_error && ack_source_node_id) {
                (void)lora_send_command_failure_ack(
                    transport,
                    config,
                    &pending->command,
                    ack_source_node_id,
                    failure_error
                );
            }
            break;
        case LORA_PENDING_COMMAND_NONE:
            break;
    }

    if (stats) {
        if (handled) {
            stats->executed_commands++;
        } else {
            stats->command_failures++;
        }
    }

    if (handled) {
        lora_remember_recent_command(
            recent_commands,
            recent_command_count,
            next_recent_command,
            &pending->command
        );
    }

    pending->type = LORA_PENDING_COMMAND_NONE;
}

void service_lora_command_window(
    lora_transport_t *transport,
    lora_frame_buffer_t *buffer,
    const node_config_t *config,
    uint32_t timeout_ms,
    lora_pending_command_t *pending,
    const lora_recent_command_t *recent_commands,
    size_t recent_command_count,
    lora_command_window_stats_t *stats
) {
    if (!transport || !transport->initialized || !buffer || !config || timeout_ms == 0u) {
        return;
    }

    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        bool read_any = false;
        while (uart_is_readable(transport->config.uart)) {
            read_any = true;
            char byte = (char)uart_getc(transport->config.uart);
            const char *frame = NULL;
            lora_transport_frame_result_t frame_result =
                lora_frame_buffer_feed(buffer, byte, &frame, NULL);

            if (frame_result == LORA_TRANSPORT_FRAME_OVERSIZED) {
                if (stats) {
                    stats->oversized_frames++;
                }
                continue;
            }
            if (frame_result != LORA_TRANSPORT_FRAME_READY) {
                continue;
            }

            if (stats) {
                stats->frames++;
            }

            lora_command_t command = {0};
            lora_command_parse_result_t parse_result =
                lora_parse_command_frame(config, frame, &command);
            lora_record_parse_result(stats, parse_result);
            if (parse_result == LORA_COMMAND_PARSE_REQUEST_READING) {
                lora_queue_parsed_request_reading_command(
                    &command,
                    pending,
                    recent_commands,
                    recent_command_count,
                    stats
                );
            }
        }

        watchdog_update();
        if (!read_any) {
            sleep_ms(5);
        }
    }
}

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
) {
    if (!transport || !transport->initialized || timeout_ms == 0u) {
        return;
    }

    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        service_lora_command_window(
            transport,
            buffer,
            config,
            VG_LORA_COMMAND_WINDOW_MS,
            pending,
            recent_commands,
            recent_command_count,
            stats
        );
        handle_pending_lora_command(
            transport,
            config,
            pending,
            recent_commands,
            recent_command_count,
            next_recent_command,
            air_temperature_c,
            humidity_percent,
            environment_valid,
            soil_sensors_initialized,
            stats
        );
        watchdog_update();
    }
}

void log_lora_command_window_summary(const lora_command_window_stats_t *stats) {
    if (!lora_command_window_had_activity(stats)) {
        return;
    }

    printf("[lora] command window frames=%u valid=%u queued=%u duplicates=%u dropped=%u executed=%u failures=%u malformed=%u wrong_target=%u oversized=%u ignored=%u\n",
        (unsigned)stats->frames,
        (unsigned)stats->valid_commands,
        (unsigned)stats->queued_commands,
        (unsigned)stats->duplicate_commands,
        (unsigned)stats->dropped_commands,
        (unsigned)stats->executed_commands,
        (unsigned)stats->command_failures,
        (unsigned)stats->malformed_frames,
        (unsigned)stats->wrong_target_frames,
        (unsigned)stats->oversized_frames,
        (unsigned)stats->ignored_frames);
    stdio_flush();
}

#endif
