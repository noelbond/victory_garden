#include <stdio.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "hardware/uart.h"
#include "pico/stdlib.h"
#include "pico/stdio/driver.h"
#include "pico/stdio_usb.h"

#include "json_lite.h"

#define LORA_UART uart1

#define PIN_TX 8
#define PIN_RX 9
#define PIN_AUX 10
#define PIN_M0 4
#define PIN_M1 3

#define LORA_BAUD_RATE 9600
#define LORA_MAX_FRAME_SIZE 1024
#define LORA_NODE_ID "sensor-zone1-ch0"
#define LORA_ZONE_ID "zone1"
#define LORA_COMMAND_SCHEMA_VERSION "lora-command/v1"
#define LORA_COMMAND_REQUEST_READING "request_reading"
#define LORA_COMPACT_COMMAND_TYPE "cmd"
#define LORA_COMPACT_COMMAND_REQUEST_READING "rr"
#define LORA_TEST_MOISTURE_RAW 2345
#define LORA_TEST_MOISTURE_PERCENT 55
#define LORA_IDLE_TIMEOUT_MS 25000

typedef struct {
    char frame[LORA_MAX_FRAME_SIZE + 1];
    size_t length;
    bool discarding_oversized_frame;
} lora_command_frame_buffer_t;

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

static const char *lora_command_parse_result_name(lora_command_parse_result_t result) {
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

static lora_command_parse_result_t parse_lora_command_frame(
    const char *frame,
    char *message_id,
    size_t message_id_size,
    char *target_node_id,
    size_t target_node_id_size,
    int *sequence_out
) {
    char schema[32] = {0};
    char command[32] = {0};
    char compact_type[16] = {0};
    int sequence = 0;

    if (sequence_out) {
        *sequence_out = 0;
    }

    if (!is_well_formed_json_object_frame(frame)) {
        return LORA_COMMAND_PARSE_MALFORMED;
    }

    (void)extract_json_string(frame, "t", compact_type, sizeof(compact_type));
    if (compact_type[0] != '\0') {
        if (strcmp(compact_type, LORA_COMPACT_COMMAND_TYPE) != 0) {
            return LORA_COMMAND_PARSE_WRONG_SCHEMA;
        }

        (void)extract_json_string(frame, "mid", message_id, message_id_size);
        (void)extract_json_string(frame, "n", target_node_id, target_node_id_size);
        if (extract_json_int(frame, "sq", &sequence)) {
            if (sequence < 1) {
                return LORA_COMMAND_PARSE_INVALID_SEQUENCE;
            }
            if (sequence_out) {
                *sequence_out = sequence;
            }
        }

        if (message_id[0] == '\0' ||
            target_node_id[0] == '\0' ||
            !extract_json_string(frame, "c", command, sizeof(command))) {
            return LORA_COMMAND_PARSE_MISSING_FIELD;
        }

        if (!is_mqtt_safe_identifier(message_id)) {
            return LORA_COMMAND_PARSE_INVALID_IDENTIFIER;
        }

        if (strcmp(target_node_id, LORA_NODE_ID) != 0) {
            return LORA_COMMAND_PARSE_WRONG_TARGET;
        }

        if (strcmp(command, LORA_COMPACT_COMMAND_REQUEST_READING) != 0) {
            return LORA_COMMAND_PARSE_UNSUPPORTED_COMMAND;
        }

        return LORA_COMMAND_PARSE_REQUEST_READING;
    }

    (void)extract_json_string(frame, "message_id", message_id, message_id_size);
    (void)extract_json_string(frame, "target_node_id", target_node_id, target_node_id_size);

    if (!extract_json_string(frame, "schema_version", schema, sizeof(schema)) ||
        message_id[0] == '\0' ||
        target_node_id[0] == '\0' ||
        !extract_json_string(frame, "command", command, sizeof(command))) {
        return LORA_COMMAND_PARSE_MISSING_FIELD;
    }

    if (!is_mqtt_safe_identifier(message_id)) {
        return LORA_COMMAND_PARSE_INVALID_IDENTIFIER;
    }

    if (strcmp(schema, LORA_COMMAND_SCHEMA_VERSION) != 0) {
        return LORA_COMMAND_PARSE_WRONG_SCHEMA;
    }

    if (strcmp(target_node_id, LORA_NODE_ID) != 0) {
        return LORA_COMMAND_PARSE_WRONG_TARGET;
    }

    if (strcmp(command, LORA_COMMAND_REQUEST_READING) != 0) {
        return LORA_COMMAND_PARSE_UNSUPPORTED_COMMAND;
    }

    return LORA_COMMAND_PARSE_REQUEST_READING;
}

static bool wait_for_lora_idle(uint32_t timeout_ms) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);

    while (!time_reached(deadline)) {
        if (gpio_get(PIN_AUX) == 0) {
            sleep_ms(50);
            return gpio_get(PIN_AUX) == 0;
        }
        sleep_ms(5);
    }

    return false;
}

static void send_lora_compact_state_response(const char *correlation_id, int sequence) {
    char payload[384];
    uint32_t uptime_seconds = to_ms_since_boot(get_absolute_time()) / 1000;
    int payload_length;

    if (sequence > 0) {
        payload_length = snprintf(
            payload,
            sizeof(payload),
            "{\"t\":\"state\","
            "\"z\":\"%s\","
            "\"n\":\"%s\","
            "\"mid\":\"%s\","
            "\"mr\":%d,"
            "\"mp\":%d,"
            "\"sq\":%d,"
            "\"up\":%lu}\n",
            LORA_ZONE_ID,
            LORA_NODE_ID,
            correlation_id,
            LORA_TEST_MOISTURE_RAW,
            LORA_TEST_MOISTURE_PERCENT,
            sequence,
            (unsigned long)uptime_seconds
        );
    } else {
        payload_length = snprintf(
            payload,
            sizeof(payload),
            "{\"t\":\"state\","
            "\"z\":\"%s\","
            "\"n\":\"%s\","
            "\"mid\":\"%s\","
            "\"mr\":%d,"
            "\"mp\":%d,"
            "\"up\":%lu}\n",
            LORA_ZONE_ID,
            LORA_NODE_ID,
            correlation_id,
            LORA_TEST_MOISTURE_RAW,
            LORA_TEST_MOISTURE_PERCENT,
            (unsigned long)uptime_seconds
        );
    }

    if (payload_length < 0 || (size_t)payload_length >= sizeof(payload)) {
        printf("[LoRa compact state not sent: payload_too_large]\n");
        return;
    }

    if (!wait_for_lora_idle(LORA_IDLE_TIMEOUT_MS)) {
        printf("[LoRa compact state not sent: radio_busy]\n");
        return;
    }

    uart_puts(LORA_UART, payload);
    printf("[LoRa compact state sent: mid=%s sq=%d bytes=%d]\n",
           correlation_id,
           sequence,
           payload_length);
}

static void handle_lora_command_frame(const char *frame, size_t length) {
    char message_id[128] = {0};
    char target_node_id[80] = {0};
    int sequence = 0;
    lora_command_parse_result_t result = parse_lora_command_frame(
        frame,
        message_id,
        sizeof(message_id),
        target_node_id,
        sizeof(target_node_id),
        &sequence
    );

    printf("\n[LoRa command frame buffered: %lu bytes]\n", (unsigned long)length);
    printf("%.*s\n", (int)length, frame);
    if (result == LORA_COMMAND_PARSE_REQUEST_READING) {
        printf("[LoRa command accepted: request_reading message_id=%s target=%s sq=%d]\n",
               message_id,
               LORA_NODE_ID,
               sequence);
        send_lora_compact_state_response(message_id, sequence);
    } else if (result == LORA_COMMAND_PARSE_WRONG_TARGET ||
               result == LORA_COMMAND_PARSE_MALFORMED ||
               message_id[0] == '\0' ||
               strcmp(target_node_id, LORA_NODE_ID) != 0) {
        printf("[LoRa command ignored: %s]\n", lora_command_parse_result_name(result));
    } else {
        printf("[LoRa command ignored: %s]\n", lora_command_parse_result_name(result));
    }
}

static void lora_command_frame_buffer_feed(lora_command_frame_buffer_t *buffer, char byte) {
    if (buffer->discarding_oversized_frame) {
        if (byte == '\n') {
            buffer->discarding_oversized_frame = false;
            buffer->length = 0;
            printf("\n[LoRa command frame discarded: oversized]\n");
        }
        return;
    }

    if (byte == '\n') {
        size_t frame_length = buffer->length;
        if (frame_length > 0 && buffer->frame[frame_length - 1] == '\r') {
            frame_length--;
        }

        buffer->frame[frame_length] = '\0';
        if (frame_length > 0) {
            handle_lora_command_frame(buffer->frame, frame_length);
        }
        buffer->length = 0;
        return;
    }

    if (buffer->length >= LORA_MAX_FRAME_SIZE) {
        buffer->discarding_oversized_frame = true;
        buffer->length = 0;
        return;
    }

    buffer->frame[buffer->length++] = byte;
}

int main(void) {
    stdio_init_all();

    absolute_time_t usb_wait_deadline = make_timeout_time_ms(15000);
    while (!stdio_usb_connected() && !time_reached(usb_wait_deadline)) {
        sleep_ms(10);
    }

    printf("LoRa test starting...\n");

    uart_init(LORA_UART, LORA_BAUD_RATE);
    gpio_set_function(PIN_TX, GPIO_FUNC_UART);
    gpio_set_function(PIN_RX, GPIO_FUNC_UART);

    gpio_init(PIN_AUX);
    gpio_set_dir(PIN_AUX, GPIO_IN);

    // If AT+SWITCH=1, M0=0/M1=0 selects high-efficiency mode. With the
    // factory AT+SWITCH=0 setting, the LR22 drives both pins low itself, so
    // the levels still agree.
    gpio_init(PIN_M0);
    gpio_set_dir(PIN_M0, GPIO_OUT);
    gpio_put(PIN_M0, 0);

    gpio_init(PIN_M1);
    gpio_set_dir(PIN_M1, GPIO_OUT);
    gpio_put(PIN_M1, 0);

    printf("UART1 initialized at %d baud\n", LORA_BAUD_RATE);
    printf("AUX = %d (0=idle, 1=radio active)\n", gpio_get(PIN_AUX));
    printf("LR22 UART fixed at %d baud; startup AT probe disabled\n", LORA_BAUD_RATE);
    printf("USB <-> LoRa UART bridge ready\n");
    printf("LoRa command target node_id = %s\n", LORA_NODE_ID);
    printf("LoRa compact state zone_id = %s\n", LORA_ZONE_ID);

    lora_command_frame_buffer_t lora_command_buffer = {0};

    while (true) {
        char usb_buffer[64];
        int usb_count = stdio_usb.in_chars(usb_buffer, sizeof(usb_buffer));
        if (usb_count > 0) {
            uart_write_blocking(LORA_UART, (const uint8_t *)usb_buffer,
                                (size_t)usb_count);
            printf("[USB->UART %d bytes]\n", usb_count);
        }

        while (uart_is_readable(LORA_UART)) {
            char byte = (char)uart_getc(LORA_UART);
            putchar_raw(byte);
            lora_command_frame_buffer_feed(&lora_command_buffer, byte);
        }

        sleep_ms(5);
    }
}
