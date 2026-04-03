#include "sensors.h"

#include <stdio.h>

#include <hardware/gpio.h>
#include <hardware/i2c.h>
#include <pico/time.h>

#define SEESAW_STATUS_BASE 0x00
#define SEESAW_STATUS_HW_ID 0x01
#define SEESAW_TOUCH_BASE 0x0F
#define SEESAW_TOUCH_CHANNEL_OFFSET 0x10

#define SEESAW_HW_ID_CODE_SAMD09 0x55
#define SEESAW_HW_ID_CODE_TINY806 0x84
#define SEESAW_HW_ID_CODE_TINY807 0x85
#define SEESAW_HW_ID_CODE_TINY816 0x86
#define SEESAW_HW_ID_CODE_TINY817 0x87
#define SEESAW_HW_ID_CODE_TINY1616 0x88
#define SEESAW_HW_ID_CODE_TINY1617 0x89

#define SEESAW_FALLBACK_RAW_DRY 200u
#define SEESAW_FALLBACK_RAW_WET 2000u

static bool g_i2c_initialized = false;
static bool g_sensor_detected = false;
static bool g_bus_debug_logged = false;

static int clamp_percent(int percent) {
    if (percent < 0) {
        return 0;
    }
    if (percent > 100) {
        return 100;
    }
    return percent;
}

static bool seesaw_hw_id_supported(uint8_t hw_id) {
    switch (hw_id) {
        case SEESAW_HW_ID_CODE_SAMD09:
        case SEESAW_HW_ID_CODE_TINY806:
        case SEESAW_HW_ID_CODE_TINY807:
        case SEESAW_HW_ID_CODE_TINY816:
        case SEESAW_HW_ID_CODE_TINY817:
        case SEESAW_HW_ID_CODE_TINY1616:
        case SEESAW_HW_ID_CODE_TINY1617:
            return true;
        default:
            return false;
    }
}

static void seesaw_init_bus(const node_config_t *config) {
    if (g_i2c_initialized) {
        return;
    }

    i2c_init(i2c0, 100 * 1000);
    gpio_set_function(config->seesaw_i2c_sda_gpio, GPIO_FUNC_I2C);
    gpio_set_function(config->seesaw_i2c_scl_gpio, GPIO_FUNC_I2C);
    gpio_pull_up(config->seesaw_i2c_sda_gpio);
    gpio_pull_up(config->seesaw_i2c_scl_gpio);
    g_i2c_initialized = true;
}

static void seesaw_log_bus_debug(const node_config_t *config) {
    if (g_bus_debug_logged || !config) {
        return;
    }

    printf(
        "[sensors] seesaw config: sda=GP%u scl=GP%u addr=0x%02X channel=%u dry=%u wet=%u\n",
        (unsigned)config->seesaw_i2c_sda_gpio,
        (unsigned)config->seesaw_i2c_scl_gpio,
        (unsigned)config->seesaw_i2c_address,
        (unsigned)config->seesaw_touch_channel,
        (unsigned)config->moisture_raw_dry,
        (unsigned)config->moisture_raw_wet
    );

    bool found_any = false;
    for (uint8_t addr = 0x30; addr <= 0x3F; ++addr) {
        int rc = i2c_write_blocking(i2c0, addr, NULL, 0, false);
        if (rc >= 0) {
            printf("[sensors] i2c ack at 0x%02X\n", (unsigned)addr);
            found_any = true;
        }
    }

    if (!found_any) {
        printf("[sensors] i2c scan: no devices acked in 0x30-0x3F\n");
    }

    g_bus_debug_logged = true;
}

static bool seesaw_read(const node_config_t *config, uint8_t reg_high, uint8_t reg_low,
                        uint8_t *buf, size_t len, uint32_t delay_us) {
    uint8_t prefix[2] = {reg_high, reg_low};

    if (i2c_write_blocking(i2c0, config->seesaw_i2c_address, prefix, 2, true) != 2) {
        return false;
    }

    sleep_us(delay_us);

    return i2c_read_blocking(i2c0, config->seesaw_i2c_address, buf, len, false) == (int)len;
}

static bool seesaw_detect(const node_config_t *config) {
    uint8_t hw_id = 0;

    seesaw_init_bus(config);
    seesaw_log_bus_debug(config);
    if (!seesaw_read(config, SEESAW_STATUS_BASE, SEESAW_STATUS_HW_ID, &hw_id, 1, 10000)) {
        printf("[sensors] detect failed at addr=0x%02X\n", (unsigned)config->seesaw_i2c_address);
        return false;
    }

    printf("[sensors] hw_id=0x%02X supported=%d\n", (unsigned)hw_id, (int)seesaw_hw_id_supported(hw_id));
    return seesaw_hw_id_supported(hw_id);
}

static bool seesaw_touch_read(const node_config_t *config, uint16_t *raw_out) {
    uint8_t buf[2] = {0};

    for (uint8_t retry = 0; retry < 5; ++retry) {
        if (seesaw_read(
                config,
                SEESAW_TOUCH_BASE,
                (uint8_t)(SEESAW_TOUCH_CHANNEL_OFFSET + config->seesaw_touch_channel),
                buf,
                sizeof(buf),
                (uint32_t)(3000 + retry * 1000)
            )) {
            *raw_out = (uint16_t)(((uint16_t)buf[0] << 8) | buf[1]);
            return true;
        }
    }

    return false;
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

    g_sensor_detected = seesaw_detect(config);
}

bool sensors_read(const node_config_t *config, sensor_snapshot_t *out) {
    uint16_t raw = 0;

    if (!config || !out) {
        return false;
    }

    if (!g_sensor_detected) {
        g_sensor_detected = seesaw_detect(config);
        if (!g_sensor_detected) {
            return false;
        }
    }

    if (!seesaw_touch_read(config, &raw)) {
        return false;
    }

    out->moisture_raw = raw;
    out->moisture_percent = percent_from_calibration(config, raw);
    out->healthy = !(raw == 0 || raw == 65535u || raw > 3000u);
    return true;
}
