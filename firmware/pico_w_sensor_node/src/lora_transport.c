#include "lora_transport.h"

#include <hardware/gpio.h>
#include <pico/stdlib.h>
#include <string.h>

static bool gpio_number_valid(int gpio) {
    return gpio >= 0 && gpio <= 29;
}

static bool optional_gpio_valid(int gpio) {
    return gpio < 0 || gpio_number_valid(gpio);
}

static bool config_valid(const lora_transport_config_t *config) {
    return config &&
        config->uart &&
        config->baud_rate > 0 &&
        gpio_number_valid((int)config->tx_gpio) &&
        gpio_number_valid((int)config->rx_gpio) &&
        optional_gpio_valid(config->aux_gpio) &&
        optional_gpio_valid(config->m0_gpio) &&
        optional_gpio_valid(config->m1_gpio);
}

lora_transport_config_t lora_transport_default_config(void) {
    return (lora_transport_config_t){
        .uart = uart1,
        .baud_rate = VG_DEFAULT_LORA_BAUD_RATE,
        .tx_gpio = VG_DEFAULT_LORA_TX_GPIO,
        .rx_gpio = VG_DEFAULT_LORA_RX_GPIO,
        .aux_gpio = VG_DEFAULT_LORA_AUX_GPIO,
        .m0_gpio = VG_DEFAULT_LORA_M0_GPIO,
        .m1_gpio = VG_DEFAULT_LORA_M1_GPIO,
        .idle_timeout_ms = VG_DEFAULT_LORA_IDLE_TIMEOUT_MS,
    };
}

bool lora_transport_init(lora_transport_t *transport, const lora_transport_config_t *config) {
    if (!transport || !config_valid(config)) {
        return false;
    }

    memset(transport, 0, sizeof(*transport));
    transport->config = *config;

    uart_init(config->uart, config->baud_rate);
    gpio_set_function(config->tx_gpio, GPIO_FUNC_UART);
    gpio_set_function(config->rx_gpio, GPIO_FUNC_UART);

    if (config->aux_gpio >= 0) {
        gpio_init((uint)config->aux_gpio);
        gpio_set_dir((uint)config->aux_gpio, GPIO_IN);
    }

    if (config->m0_gpio >= 0) {
        gpio_init((uint)config->m0_gpio);
        gpio_set_dir((uint)config->m0_gpio, GPIO_OUT);
        gpio_put((uint)config->m0_gpio, 0);
    }

    if (config->m1_gpio >= 0) {
        gpio_init((uint)config->m1_gpio);
        gpio_set_dir((uint)config->m1_gpio, GPIO_OUT);
        gpio_put((uint)config->m1_gpio, 0);
    }

    transport->initialized = true;
    return true;
}

bool lora_transport_wait_idle(const lora_transport_t *transport, uint32_t timeout_ms) {
    if (!transport || !transport->initialized) {
        return false;
    }

    if (transport->config.aux_gpio < 0) {
        return true;
    }

    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    while (!time_reached(deadline)) {
        if (gpio_get((uint)transport->config.aux_gpio) == 0) {
            sleep_ms(50);
            return gpio_get((uint)transport->config.aux_gpio) == 0;
        }
        sleep_ms(5);
    }

    return false;
}

bool lora_transport_send_frame(lora_transport_t *transport, const char *frame, size_t length) {
    if (!transport || !transport->initialized || !frame) {
        return false;
    }

    if (!lora_transport_wait_idle(transport, transport->config.idle_timeout_ms)) {
        return false;
    }

    uart_write_blocking(transport->config.uart, (const uint8_t *)frame, length);
    return true;
}

void lora_frame_buffer_reset(lora_frame_buffer_t *buffer) {
    if (!buffer) {
        return;
    }

    memset(buffer, 0, sizeof(*buffer));
}

lora_transport_frame_result_t lora_frame_buffer_feed(
    lora_frame_buffer_t *buffer,
    char byte,
    const char **frame_out,
    size_t *length_out
) {
    if (frame_out) {
        *frame_out = NULL;
    }
    if (length_out) {
        *length_out = 0;
    }
    if (!buffer) {
        return LORA_TRANSPORT_FRAME_NONE;
    }

    if (buffer->discarding_oversized_frame) {
        if (byte == '\n') {
            buffer->discarding_oversized_frame = false;
            buffer->length = 0;
            return LORA_TRANSPORT_FRAME_OVERSIZED;
        }
        return LORA_TRANSPORT_FRAME_NONE;
    }

    if (byte == '\n') {
        size_t frame_length = buffer->length;
        if (frame_length > 0 && buffer->frame[frame_length - 1u] == '\r') {
            frame_length--;
        }

        buffer->frame[frame_length] = '\0';
        buffer->length = 0;
        if (frame_length == 0) {
            return LORA_TRANSPORT_FRAME_NONE;
        }

        if (frame_out) {
            *frame_out = buffer->frame;
        }
        if (length_out) {
            *length_out = frame_length;
        }
        return LORA_TRANSPORT_FRAME_READY;
    }

    if (buffer->length >= VG_LORA_MAX_FRAME_SIZE) {
        buffer->discarding_oversized_frame = true;
        buffer->length = 0;
        return LORA_TRANSPORT_FRAME_NONE;
    }

    buffer->frame[buffer->length++] = byte;
    return LORA_TRANSPORT_FRAME_NONE;
}
