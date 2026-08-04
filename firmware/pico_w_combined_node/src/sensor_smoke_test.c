/*
 * Standalone hardware bring-up test — no Wi-Fi/MQTT, and critically no
 * relay/mqtt_node code at all: this binary never links wifi.c, mqtt_node.c,
 * or hardware_gpio for GP16..GP19, so it structurally cannot energize a
 * relay, not just "won't by policy."
 *
 * Takes 10 readings, 5s apart, from the SHT40 (if present) and all four
 * ADS1115 soil moisture channels.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "config.h"
#include "pico/stdlib.h"
#include "sensors.h"
#include "sht40.h"

static const uint32_t READING_COUNT = 10u;
static const uint32_t READING_GAP_MS = 5000u;

int main(void) {
    stdio_init_all();
    sleep_ms(2500);

    node_config_t config;
    node_config_reset_defaults(&config);

    printf("[sensor-test] boot ads1115 sda=GP%u scl=GP%u addr=0x%02X channels=%u\n",
        (unsigned)config.ads1115_i2c_sda_gpio,
        (unsigned)config.ads1115_i2c_scl_gpio,
        (unsigned)config.ads1115_i2c_address,
        (unsigned)VG_ADS1115_CHANNEL_COUNT);
    printf("[sensor-test] plan: %lu reading(s), %lums apart — sensors only, no relay GPIO in this build\n",
        (unsigned long)READING_COUNT, (unsigned long)READING_GAP_MS);
    stdio_flush();

    for (uint32_t reading = 1; reading <= READING_COUNT; ++reading) {
        printf("[sensor-test] --- reading %lu/%lu ---\n", (unsigned long)reading, (unsigned long)READING_COUNT);
        stdio_flush();

        float air_temperature_c = 0.0f;
        float humidity_percent = 0.0f;
        bool environment_valid = sht40_read(&config, &air_temperature_c, &humidity_percent);
        if (environment_valid) {
            printf("[sensor-test] sht40 temp_c=%.2f humidity=%.2f\n",
                (double)air_temperature_c, (double)humidity_percent);
        } else {
            bool present = sht40_probe(&config);
            printf("[sensor-test] sht40 read failed; 0x44 %s\n", present ? "present" : "missing");
        }
        stdio_flush();

        sensors_init(&config);
        for (uint8_t ch = 0; ch < VG_ADS1115_CHANNEL_COUNT; ++ch) {
            sensor_snapshot_t snapshot = {0};
            bool ok = sensors_read(&config, ch, &snapshot);
            if (ok) {
                printf("[sensor-test] channel %u node=%s moisture_raw=%u moisture_percent=%d healthy=%s\n",
                    (unsigned)ch,
                    config.channel_node_id[ch],
                    (unsigned)snapshot.moisture_raw,
                    snapshot.moisture_percent,
                    snapshot.healthy ? "true" : "false");
            } else {
                printf("[sensor-test] channel %u node=%s read FAILED\n",
                    (unsigned)ch, config.channel_node_id[ch]);
            }
            stdio_flush();
        }

        if (reading < READING_COUNT) {
            printf("[sensor-test] waiting %lums\n", (unsigned long)READING_GAP_MS);
            stdio_flush();
            sleep_ms(READING_GAP_MS);
        }
    }

    printf("[sensor-test] DONE — %lu readings complete. No relay GPIO was ever configured.\n",
        (unsigned long)READING_COUNT);
    stdio_flush();

    while (true) {
        sleep_ms(10000);
        printf("[sensor-test] idle, test complete\n");
        stdio_flush();
    }
}
