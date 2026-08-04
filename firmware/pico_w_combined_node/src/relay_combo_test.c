/*
 * Standalone hardware bring-up test — no Wi-Fi/MQTT, just GP16..GP19 relay
 * control. Runs three simultaneous-relay steps, each for 2s, with a 5s gap
 * between them: K1+K2, then K1+K2+K3, then K1+K2+K3+K4. Then re-asserts OFF
 * on all four and reads back each pin's driven level to confirm, and idles
 * printing a "done" status.
 *
 * Same active-low polarity + preload-before-enable-output fix as
 * relay_sequence_test.c — see that file's comments for why.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "hardware/gpio.h"
#include "pico/stdlib.h"

static const uint8_t RELAY_GPIOS[] = {16u, 17u, 18u, 19u};
static const size_t RELAY_COUNT = sizeof(RELAY_GPIOS) / sizeof(RELAY_GPIOS[0]);

static const uint32_t ON_MS = 2000u;
static const uint32_t GAP_MS = 5000u;

/* Confirmed active-low on hardware: LOW = relay on, HIGH = relay off. */
#ifndef RELAY_ACTIVE_HIGH
#define RELAY_ACTIVE_HIGH 0
#endif

static bool on_level(void) {
    return RELAY_ACTIVE_HIGH ? true : false;
}

static bool off_level(void) {
    return !on_level();
}

static void set_relays(uint8_t selected_mask) {
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        bool enabled = (selected_mask & (1u << i)) != 0;
        bool level = enabled ? on_level() : off_level();
        gpio_put(RELAY_GPIOS[i], level ? 1u : 0u);
    }
}

static void print_selected(const char *label, uint8_t selected_mask) {
    printf("[relay-combo-test] %s:", label);
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        if ((selected_mask & (1u << i)) != 0) {
            printf(" K%u/GP%u", (unsigned)(i + 1u), (unsigned)RELAY_GPIOS[i]);
        }
    }
    if (selected_mask == 0) {
        printf(" none");
    }
    printf("\n");
    stdio_flush();
}

static void initialize_relays(void) {
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        // Preload the OFF level before enabling the output driver — avoids a
        // brief drive-LOW (relay ON) glitch on this active-low board between
        // gpio_set_dir(GPIO_OUT) and the first explicit gpio_put().
        gpio_init(RELAY_GPIOS[i]);
        gpio_put(RELAY_GPIOS[i], off_level() ? 1u : 0u);
        gpio_set_dir(RELAY_GPIOS[i], GPIO_OUT);
    }
}

static void run_step(const char *label, uint8_t selected_mask) {
    print_selected(label, selected_mask);
    set_relays(selected_mask);
    sleep_ms(ON_MS);

    set_relays(0);
    print_selected("off", 0);
    printf("[relay-combo-test] waiting %lums\n", (unsigned long)GAP_MS);
    stdio_flush();
    sleep_ms(GAP_MS);
}

int main(void) {
    stdio_init_all();
    initialize_relays();

    sleep_ms(2500);
    printf("[relay-combo-test] boot GP16..GP19 active_high=%d\n", RELAY_ACTIVE_HIGH ? 1 : 0);
    printf("[relay-combo-test] plan: 2-pump, 3-pump, 4-pump, on=%lums gap=%lums\n",
        (unsigned long)ON_MS, (unsigned long)GAP_MS);
    stdio_flush();

    run_step("two pumps: K1 K2", 0x03u);
    run_step("three pumps: K1 K2 K3", 0x07u);
    run_step("four pumps: K1 K2 K3 K4", 0x0Fu);

    printf("[relay-combo-test] sequence complete, re-asserting OFF on all relays\n");
    stdio_flush();

    bool all_confirmed_off = true;
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        gpio_put(RELAY_GPIOS[i], off_level() ? 1u : 0u);
        sleep_ms(5);
        bool readback_high = gpio_get(RELAY_GPIOS[i]);
        bool expected_high = off_level();
        bool ok = readback_high == expected_high;
        all_confirmed_off &= ok;
        printf("[relay-combo-test] K%u/GP%u off_confirmed=%s (pin_level=%s)\n",
            (unsigned)(i + 1u), (unsigned)RELAY_GPIOS[i],
            ok ? "true" : "FALSE",
            readback_high ? "high" : "low");
        stdio_flush();
    }

    if (all_confirmed_off) {
        printf("[relay-combo-test] DONE — all relays confirmed off. Test finished.\n");
    } else {
        printf("[relay-combo-test] DONE — WARNING: not all relay pins read back the expected off level.\n");
    }
    stdio_flush();

    while (true) {
        sleep_ms(10000);
        printf("[relay-combo-test] idle, all relays off, test complete\n");
        stdio_flush();
    }
}
