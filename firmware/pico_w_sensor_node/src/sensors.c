#include "sensors.h"
#include "seesaw.h"

#include <stdio.h>

#include <pico/stdlib.h>
#include <pico/time.h>

#define SEESAW_DETECT_RETRY_MS 5000u
#define SEESAW_POST_DETECT_SETTLE_MS 1000u
#define SEESAW_CALIBRATION_MARGIN 512u

#define SEESAW_FALLBACK_RAW_DRY 200u
#define SEESAW_FALLBACK_RAW_WET 2000u

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
    seesaw_device_info_t info = {0};
    uint16_t warmup_raw = 0;

    if (!seesaw_begin(config, &info)) {
        printf("[sensors] begin failed at addr=0x%02X\n", (unsigned)config->seesaw_i2c_address);
        fflush(stdout);
        return false;
    }

    if (info.version_valid) {
        printf("[sensors] detected hw_id=0x%02X version=0x%08lX\n",
               (unsigned)info.hw_id,
               (unsigned long)info.version);
    } else {
        printf("[sensors] detected hw_id=0x%02X version=unknown\n", (unsigned)info.hw_id);
    }
    fflush(stdout);

    seesaw_touch_read(config, &warmup_raw);
    sleep_ms(SEESAW_POST_DETECT_SETTLE_MS);
    return true;
}

static bool raw_looks_valid(uint16_t raw) {
    // Seesaw capacitive probes vary widely in raw range across hardware revisions.
    return raw != 0u && raw != 65535u;
}

static bool raw_matches_calibration_window(const node_config_t *config, uint16_t raw) {
    if (!config ||
        config->moisture_raw_dry == 0u ||
        config->moisture_raw_wet == 0u ||
        config->moisture_raw_dry == config->moisture_raw_wet) {
        return true;
    }

    uint16_t lower = config->moisture_raw_dry < config->moisture_raw_wet
        ? config->moisture_raw_dry
        : config->moisture_raw_wet;
    uint16_t upper = config->moisture_raw_dry > config->moisture_raw_wet
        ? config->moisture_raw_dry
        : config->moisture_raw_wet;

    uint32_t min_allowed = lower > SEESAW_CALIBRATION_MARGIN
        ? (uint32_t)lower - SEESAW_CALIBRATION_MARGIN
        : 0u;
    uint32_t max_allowed = (uint32_t)upper + SEESAW_CALIBRATION_MARGIN;

    return (uint32_t)raw >= min_allowed && (uint32_t)raw <= max_allowed;
}

static int percent_from_calibration(const node_config_t *config, uint16_t raw) {
    if (config->moisture_raw_dry > 0 &&
        config->moisture_raw_wet > 0 &&
        config->moisture_raw_dry != config->moisture_raw_wet) {
        int dry = (int)config->moisture_raw_dry;
        int wet = (int)config->moisture_raw_wet;
        int span = wet - dry;

        if (span != 0) {
            return clamp_percent((((int)raw - dry) * 100) / span);
        }
    }

    return clamp_percent((((int)raw - (int)SEESAW_FALLBACK_RAW_DRY) * 100) /
                         ((int)SEESAW_FALLBACK_RAW_WET - (int)SEESAW_FALLBACK_RAW_DRY));
}

void sensors_init(const node_config_t *config) {
    if (!config) {
        return;
    }

    g_sensor_detected = detect_sensor(config);
    if (!g_sensor_detected) {
        g_next_detect_allowed_at = make_timeout_time_ms(SEESAW_DETECT_RETRY_MS);
        g_next_detect_allowed_set = true;
    }
}

bool sensors_read(const node_config_t *config, sensor_snapshot_t *out) {
    uint16_t raw = 0;

    if (!config || !out) {
        return false;
    }

    if (!g_sensor_detected) {
        if (g_next_detect_allowed_set &&
            absolute_time_diff_us(get_absolute_time(), g_next_detect_allowed_at) > 0) {
            return false;
        }

        g_sensor_detected = detect_sensor(config);
        if (!g_sensor_detected) {
            g_next_detect_allowed_at = make_timeout_time_ms(SEESAW_DETECT_RETRY_MS);
            g_next_detect_allowed_set = true;
            return false;
        }
        g_next_detect_allowed_set = false;
    }

    if (!seesaw_touch_read(config, &raw)) {
        printf("[sensors] touch read failed\n");
        fflush(stdout);
        g_sensor_detected = false;
        g_next_detect_allowed_at = make_timeout_time_ms(SEESAW_DETECT_RETRY_MS);
        g_next_detect_allowed_set = true;
        return false;
    }

    if (!raw_looks_valid(raw) || !raw_matches_calibration_window(config, raw)) {
        return false;
    }

    out->moisture_raw = raw;
    out->moisture_percent = percent_from_calibration(config, raw);
    out->healthy = raw_looks_valid(raw);
    return true;
}
