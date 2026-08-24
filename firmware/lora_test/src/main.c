#include <stdio.h>

#include "hardware/uart.h"
#include "pico/stdlib.h"
#include "pico/stdio/driver.h"
#include "pico/stdio_usb.h"

#define LORA_UART uart1

#define PIN_TX 8
#define PIN_RX 9
#define PIN_AUX 10
#define PIN_M0 4
#define PIN_M1 3

#define LORA_BAUD_RATE 9600

static int read_radio_for_ms(uint32_t duration_ms) {
    int received = 0;
    absolute_time_t deadline = make_timeout_time_ms(duration_ms);

    while (!time_reached(deadline)) {
        while (uart_is_readable(LORA_UART)) {
            putchar_raw(uart_getc(LORA_UART));
            received++;
        }
        sleep_ms(1);
    }

    return received;
}

static uint32_t probe_radio_baud(void) {
    static const uint32_t baud_rates[] = {
        2400, 4800, 9600, 19200, 38400, 57600, 115200,
    };

    printf("Probing LR22 UART baud...\n");
    for (size_t i = 0; i < count_of(baud_rates); i++) {
        uint32_t baud = baud_rates[i];
        uart_set_baudrate(LORA_UART, baud);
        while (uart_is_readable(LORA_UART)) {
            (void)uart_getc(LORA_UART);
        }

        printf("[probe %lu] ", (unsigned long)baud);
        uart_puts(LORA_UART, "+++\r\n");
        int received = read_radio_for_ms(750);
        uart_puts(LORA_UART, "AT\r\n");
        received += read_radio_for_ms(750);
        printf("%s\n", received > 0 ? "response detected" : "no response");

        if (received > 0) {
            printf("Returning LR22 to transparent transmission...\n");
            uart_puts(LORA_UART, "+++\r\n");
            (void)read_radio_for_ms(1500);
            sleep_ms(500);
            return baud;
        }
    }

    uart_set_baudrate(LORA_UART, LORA_BAUD_RATE);
    return 0;
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
    uint32_t detected_baud = probe_radio_baud();
    if (detected_baud > 0) {
        printf("LR22 detected at %lu baud\n", (unsigned long)detected_baud);
    } else {
        printf("No LR22 UART response; using %d baud\n", LORA_BAUD_RATE);
    }
    printf("USB <-> LoRa UART bridge ready\n");

    while (true) {
        char usb_buffer[64];
        int usb_count = stdio_usb.in_chars(usb_buffer, sizeof(usb_buffer));
        if (usb_count > 0) {
            uart_write_blocking(LORA_UART, (const uint8_t *)usb_buffer,
                                (size_t)usb_count);
            printf("[USB->UART %d bytes]\n", usb_count);
        }

        while (uart_is_readable(LORA_UART)) {
            putchar_raw(uart_getc(LORA_UART));
        }

        sleep_ms(5);
    }
}
