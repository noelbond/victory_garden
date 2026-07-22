#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "hardware/gpio.h"
#include "pico/stdlib.h"

static const uint8_t RELAY_GPIOS[] = {16u, 17u, 18u, 19u};
static const size_t RELAY_COUNT = sizeof(RELAY_GPIOS) / sizeof(RELAY_GPIOS[0]);

/*
 * Most JD-VCC relay boards are active-low: GPIO low energizes the relay.
 * If your module behaves backward, rebuild with RELAY_ACTIVE_LOW=0.
 */
#ifndef RELAY_ACTIVE_LOW
#define RELAY_ACTIVE_LOW 1
#endif

static uint32_t relay_mask(void) {
    uint32_t mask = 0;
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        mask |= (1u << RELAY_GPIOS[i]);
    }
    return mask;
}

static uint32_t relay_level_mask(uint8_t selected) {
    uint32_t levels = 0;
    bool active_high = RELAY_ACTIVE_LOW ? false : true;

    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        bool enabled = (selected & (1u << i)) != 0;
        bool level = enabled ? active_high : !active_high;
        if (level) {
            levels |= (1u << RELAY_GPIOS[i]);
        }
    }

    return levels;
}

static void set_relays(uint8_t selected) {
    gpio_put_masked(relay_mask(), relay_level_mask(selected));
}

static void print_selected(const char *label, uint8_t selected) {
    printf("[relay-test] %s:", label);
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        if ((selected & (1u << i)) != 0) {
            printf(" K%u/GP%u", (unsigned)(i + 1u), (unsigned)RELAY_GPIOS[i]);
        }
    }
    if (selected == 0) {
        printf(" all off");
    }
    printf("\n");
    stdio_flush();
}

static void pulse(const char *label, uint8_t selected, uint32_t on_ms) {
    print_selected(label, selected);
    set_relays(selected);
    sleep_ms(on_ms);
    set_relays(0);
    print_selected("off", 0);
    sleep_ms(900);
}

static void initialize_relays(void) {
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        gpio_init(RELAY_GPIOS[i]);
        gpio_set_dir(RELAY_GPIOS[i], GPIO_OUT);
    }
    set_relays(0);
}

int main(void) {
    stdio_init_all();
    initialize_relays();

    sleep_ms(2500);
    printf("[relay-test] boot GP16..GP19 active_low=%d\n", RELAY_ACTIVE_LOW ? 1 : 0);
    printf("[relay-test] sequence: all four, triples, pairs, singles; repeats forever\n");
    stdio_flush();

    while (true) {
        pulse("all four", 0x0Fu, 1000);

        pulse("three: K1 K2 K3", 0x07u, 900);
        pulse("three: K1 K2 K4", 0x0Bu, 900);
        pulse("three: K1 K3 K4", 0x0Du, 900);
        pulse("three: K2 K3 K4", 0x0Eu, 900);

        pulse("two: K1 K2", 0x03u, 800);
        pulse("two: K1 K3", 0x05u, 800);
        pulse("two: K1 K4", 0x09u, 800);
        pulse("two: K2 K3", 0x06u, 800);
        pulse("two: K2 K4", 0x0Au, 800);
        pulse("two: K3 K4", 0x0Cu, 800);

        pulse("single: K1", 0x01u, 700);
        pulse("single: K2", 0x02u, 700);
        pulse("single: K3", 0x04u, 700);
        pulse("single: K4", 0x08u, 700);

        printf("[relay-test] cycle complete; next cycle in 5s\n");
        stdio_flush();
        sleep_ms(5000);
    }
}
