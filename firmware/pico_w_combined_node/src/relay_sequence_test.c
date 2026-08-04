/*
 * Standalone hardware bring-up test — no Wi-Fi/MQTT, just GP16..GP19 relay
 * control. Cycles through relays K1..K4 one at a time: ON for 2s, OFF, wait
 * 5s, next relay. Repeats the full 4-relay sequence twice, then re-asserts
 * OFF on all four, reads back each pin's driven level to confirm, and idles
 * printing a "done" status.
 *
 * Note: this can only confirm the GPIO pin itself is driven to the OFF
 * level (via gpio_get() loopback) — it has no way to sense the relay coil's
 * actual physical state without feedback wiring. Watch/listen to the relay
 * board directly (LEDs/click) to confirm the coils really de-energize.
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
static const uint32_t CYCLE_COUNT = 2u;

/*
 * Confirmed active-low on hardware: driving the pin LOW energizes the
 * relay, HIGH de-energizes it. This is the opposite of this firmware's
 * VG_DEFAULT_ACTUATOR_RELAY_ACTIVE_HIGH=true default in config.h — that
 * default needs revisiting for the real firmware too, not just this test.
 */
#ifndef RELAY_ACTIVE_HIGH
#define RELAY_ACTIVE_HIGH 0
#endif

static bool on_level(void) {
    return RELAY_ACTIVE_HIGH ? true : false;
}

static bool off_level(void) {
    return !on_level();
}

static void set_relay(uint8_t index, bool enabled) {
    bool level = enabled ? on_level() : off_level();
    gpio_put(RELAY_GPIOS[index], level ? 1u : 0u);
}

static void initialize_relays(void) {
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        // gpio_init() leaves the pin as an input with its output latch at 0
        // (see hardware_gpio/gpio.c). Preload the latch with the correct OFF
        // level *before* switching to output — otherwise, on an active-low
        // board, the pin would briefly drive LOW (relay ON) the instant
        // gpio_set_dir(GPIO_OUT) takes effect, until a later gpio_put()
        // corrects it.
        gpio_init(RELAY_GPIOS[i]);
        gpio_put(RELAY_GPIOS[i], off_level() ? 1u : 0u);
        gpio_set_dir(RELAY_GPIOS[i], GPIO_OUT);
    }
}

int main(void) {
    stdio_init_all();
    initialize_relays();

    sleep_ms(2500);
    printf("[relay-test] boot GP16..GP19 active_high=%d\n", RELAY_ACTIVE_HIGH ? 1 : 0);
    printf("[relay-test] plan: %u relay(s), on=%lums, gap=%lums, %lu cycle(s)\n",
        (unsigned)RELAY_COUNT, (unsigned long)ON_MS, (unsigned long)GAP_MS, (unsigned long)CYCLE_COUNT);
    stdio_flush();

    for (uint32_t cycle = 1; cycle <= CYCLE_COUNT; ++cycle) {
        for (size_t i = 0; i < RELAY_COUNT; ++i) {
            printf("[relay-test] cycle %lu/%lu: K%u/GP%u ON\n",
                (unsigned long)cycle, (unsigned long)CYCLE_COUNT,
                (unsigned)(i + 1u), (unsigned)RELAY_GPIOS[i]);
            stdio_flush();
            set_relay((uint8_t)i, true);
            sleep_ms(ON_MS);

            set_relay((uint8_t)i, false);
            printf("[relay-test] cycle %lu/%lu: K%u/GP%u OFF, waiting %lums\n",
                (unsigned long)cycle, (unsigned long)CYCLE_COUNT,
                (unsigned)(i + 1u), (unsigned)RELAY_GPIOS[i], (unsigned long)GAP_MS);
            stdio_flush();
            sleep_ms(GAP_MS);
        }
    }

    printf("[relay-test] sequence complete, re-asserting OFF on all relays\n");
    stdio_flush();

    bool all_confirmed_off = true;
    for (size_t i = 0; i < RELAY_COUNT; ++i) {
        set_relay((uint8_t)i, false);
        sleep_ms(5);
        bool readback_high = gpio_get(RELAY_GPIOS[i]);
        bool expected_high = off_level();
        bool ok = readback_high == expected_high;
        all_confirmed_off &= ok;
        printf("[relay-test] K%u/GP%u off_confirmed=%s (pin_level=%s)\n",
            (unsigned)(i + 1u), (unsigned)RELAY_GPIOS[i],
            ok ? "true" : "FALSE",
            readback_high ? "high" : "low");
        stdio_flush();
    }

    if (all_confirmed_off) {
        printf("[relay-test] DONE — all relays confirmed off. Test finished.\n");
    } else {
        printf("[relay-test] DONE — WARNING: not all relay pins read back the expected off level.\n");
    }
    stdio_flush();

    while (true) {
        sleep_ms(10000);
        printf("[relay-test] idle, all relays off, test complete\n");
        stdio_flush();
    }
}
