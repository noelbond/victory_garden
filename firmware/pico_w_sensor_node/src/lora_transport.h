#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "config.h"
#include "hardware/uart.h"
#include "pico/types.h"

typedef enum {
    LORA_TRANSPORT_FRAME_NONE,
    LORA_TRANSPORT_FRAME_READY,
    LORA_TRANSPORT_FRAME_OVERSIZED,
} lora_transport_frame_result_t;

typedef struct {
    uart_inst_t *uart;
    uint baud_rate;
    uint tx_gpio;
    uint rx_gpio;
    int aux_gpio;
    int m0_gpio;
    int m1_gpio;
    uint32_t idle_timeout_ms;
} lora_transport_config_t;

typedef struct {
    lora_transport_config_t config;
    bool initialized;
} lora_transport_t;

typedef struct {
    char frame[VG_LORA_MAX_FRAME_SIZE + 1u];
    size_t length;
    bool discarding_oversized_frame;
} lora_frame_buffer_t;

lora_transport_config_t lora_transport_default_config(void);
bool lora_transport_init(lora_transport_t *transport, const lora_transport_config_t *config);
bool lora_transport_wait_idle(const lora_transport_t *transport, uint32_t timeout_ms);
bool lora_transport_send_frame(lora_transport_t *transport, const char *frame, size_t length);
void lora_frame_buffer_reset(lora_frame_buffer_t *buffer);
lora_transport_frame_result_t lora_frame_buffer_feed(
    lora_frame_buffer_t *buffer,
    char byte,
    const char **frame_out,
    size_t *length_out
);
