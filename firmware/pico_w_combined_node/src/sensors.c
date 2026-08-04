#include "sensors.h"
#include "ads1115.h"

#include <stdio.h>

#include <pico/stdlib.h>
#include <pico/time.h>

#define ADS1115_DETECT_RETRY_MS 5000u
#define ADS1115_CALIBRATION_MARGIN 2000u

#define ADS1115_FALLBACK_RAW_DRY 10000u
#define ADS1115_FALLBACK_RAW_WET 26000u

static bool g_sensor_detected = false;
static absolute_time_t g_next_detect_allowed_at;
static bool g_next_detect_allowed_set = false;

static int clamp_percent(int percent) {
    if (percent < 0) {
        return 0;
    }
    if (percent > 100) {
        return 100;
    }
    return percent;
}

static bool detect_sensor(const node_config_t *config) {
    if (!ads1115_init(config)) {
        printf("[sensors] ads1115 init failed at addr=0x%02X\n", (unsigned)config->ads1115_i2c_address);
        fflush(stdout);
        return false;
    }

    printf("[sensors] ads1115 detected addr=0x%02X\n", (unsigned)config->ads1115_i2c_address);
    fflush(stdout);
    return true;
}

static bool raw_looks_valid(uint16_t raw) {
    return raw > 0u && raw < 32767u;
}

static bool raw_matches_calibration_window(const node_config_t *config, uint8_t channel, uint16_t raw) {
    if (!config ||
        channel >= VG_ADS1115_CHANNEL_COUNT ||
        config->channel_moisture_raw_dry[channel] == 0u ||
        config->channel_moisture_raw_wet[channel] == 0u ||
        config->channel_moisture_raw_dry[channel] == config->channel_moisture_raw_wet[channel]) {
        return true;
    }

    uint16_t dry = config->channel_moisture_raw_dry[channel];
    uint16_t wet = config->channel_moisture_raw_wet[channel];
    uint16_t lower = dry < wet ? dry : wet;
    uint16_t upper = dry > wet ? dry : wet;

    uint32_t min_allowed = lower > ADS1115_CALIBRATION_MARGIN
        ? (uint32_t)lower - ADS1115_CALIBRATION_MARGIN
        : 0u;
    uint32_t max_allowed = (uint32_t)upper + ADS1115_CALIBRATION_MARGIN;

    return (uint32_t)raw >= min_allowed && (uint32_t)raw <= max_allowed;
}

static int percent_from_calibration(const node_config_t *config, uint8_t channel, uint16_t raw) {
    if (config &&
        channel < VG_ADS1115_CHANNEL_COUNT &&
        config->channel_moisture_raw_dry[channel] > 0 &&
        config->channel_moisture_raw_wet[channel] > 0 &&
        config->channel_moisture_raw_dry[channel] != config->channel_moisture_raw_wet[channel]) {
        int dry = (int)config->channel_moisture_raw_dry[channel];
        int wet = (int)config->channel_moisture_raw_wet[channel];
        int span = wet - dry;

        if (span != 0) {
            return clamp_percent((((int)raw - dry) * 100) / span);
        }
    }

    return clamp_percent((((int)raw - (int)ADS1115_FALLBACK_RAW_DRY) * 100) /
                         ((int)ADS1115_FALLBACK_RAW_WET - (int)ADS1115_FALLBACK_RAW_DRY));
}

void sensors_init(const node_config_t *config) {
    if (!config) {
        return;
    }

    g_sensor_detected = detect_sensor(config);
    if (!g_sensor_detected) {
        g_next_detect_allowed_at = make_timeout_time_ms(ADS1115_DETECT_RETRY_MS);
        g_next_detect_allowed_set = true;
    }
}

bool sensors_read(const node_config_t *config, uint8_t channel, sensor_snapshot_t *out) {
    uint16_t raw = 0;

    if (!config || !out || channel >= VG_ADS1115_CHANNEL_COUNT) {
        return false;
    }

    if (!g_sensor_detected) {
        if (g_next_detect_allowed_set &&
            absolute_time_diff_us(get_absolute_time(), g_next_detect_allowed_at) > 0) {
            return false;
        }

        g_sensor_detected = detect_sensor(config);
        if (!g_sensor_detected) {
            g_next_detect_allowed_at = make_timeout_time_ms(ADS1115_DETECT_RETRY_MS);
            g_next_detect_allowed_set = true;
            return false;
        }
        g_next_detect_allowed_set = false;
    }

    if (!ads1115_read_channel(config, channel, &raw)) {
        printf("[sensors] ads1115 channel %u read failed\n", (unsigned)channel);
        fflush(stdout);
        g_sensor_detected = false;
        g_next_detect_allowed_at = make_timeout_time_ms(ADS1115_DETECT_RETRY_MS);
        g_next_detect_allowed_set = true;
        return false;
    }

    if (!raw_looks_valid(raw)) {
        printf("[sensors] ads1115 channel %u raw invalid value=%u\n", (unsigned)channel, (unsigned)raw);
        fflush(stdout);
        return false;
    }

    out->moisture_raw = raw;
    out->moisture_percent = percent_from_calibration(config, channel, raw);
    out->healthy = raw_matches_calibration_window(config, channel, raw);
    if (!out->healthy) {
        printf("[sensors] ads1115 channel %u raw outside calibration value=%u dry=%u wet=%u\n",
            (unsigned)channel,
            (unsigned)raw,
            (unsigned)config->channel_moisture_raw_dry[channel],
            (unsigned)config->channel_moisture_raw_wet[channel]);
        fflush(stdout);
    }
    return true;
}
