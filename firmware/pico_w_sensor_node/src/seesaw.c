#include "seesaw.h"

#include <stddef.h>

#include <hardware/gpio.h>
#include <hardware/i2c.h>
#include <pico/stdlib.h>

#define SEESAW_STATUS_BASE 0x00u
#define SEESAW_STATUS_HW_ID 0x01u
#define SEESAW_STATUS_VERSION 0x02u
#define SEESAW_STATUS_SWRST 0x7Fu
#define SEESAW_TOUCH_BASE 0x0Fu
#define SEESAW_TOUCH_CHANNEL_OFFSET 0x10u
#define SEESAW_I2C_TIMEOUT_US 50000u

static bool g_i2c_initialized = false;

static void seesaw_init_bus(const node_config_t *config) {
    if (g_i2c_initialized || !config) {
        return;
    }

    i2c_init(i2c0, 100 * 1000);
    gpio_set_function(config->seesaw_i2c_sda_gpio, GPIO_FUNC_I2C);
    gpio_set_function(config->seesaw_i2c_scl_gpio, GPIO_FUNC_I2C);
    gpio_pull_up(config->seesaw_i2c_sda_gpio);
    gpio_pull_up(config->seesaw_i2c_scl_gpio);
    g_i2c_initialized = true;
}

static bool seesaw_read(const node_config_t *config, uint8_t reg_high, uint8_t reg_low,
                        uint8_t *buf, size_t len, uint32_t delay_us) {
    uint8_t prefix[2] = {reg_high, reg_low};

    if (!config || !buf || len == 0) {
        return false;
    }

    int write_rc = i2c_write_timeout_us(
        i2c0,
        config->seesaw_i2c_address,
        prefix,
        sizeof(prefix),
        true,
        SEESAW_I2C_TIMEOUT_US
    );
    if (write_rc != (int)sizeof(prefix)) {
        return false;
    }

    sleep_us(delay_us);

    int read_rc = i2c_read_timeout_us(
        i2c0,
        config->seesaw_i2c_address,
        buf,
        len,
        false,
        SEESAW_I2C_TIMEOUT_US
    );
    return read_rc == (int)len;
}

static bool seesaw_hw_id_present(uint8_t hw_id) {
    return hw_id != 0x00u && hw_id != 0xFFu;
}

static bool seesaw_hw_id_supported_adafruit(uint8_t hw_id) {
    switch (hw_id) {
        case 0x55u:
        case 0x84u:
        case 0x85u:
        case 0x86u:
        case 0x87u:
        case 0x88u:
        case 0x89u:
            return true;
        default:
            return false;
    }
}

static bool seesaw_write8(const node_config_t *config, uint8_t reg_high, uint8_t reg_low, uint8_t value) {
    uint8_t buf[3] = {reg_high, reg_low, value};

    if (!config) {
        return false;
    }

    return i2c_write_timeout_us(
        i2c0,
        config->seesaw_i2c_address,
        buf,
        sizeof(buf),
        false,
        SEESAW_I2C_TIMEOUT_US
    ) == (int)sizeof(buf);
}

bool seesaw_begin_adafruit(const node_config_t *config, seesaw_device_info_t *info, bool reset) {
    uint8_t hw_id = 0;
    uint8_t version_buf[4] = {0};
    bool found = false;

    if (info) {
        info->hw_id = 0;
        info->version = 0;
        info->version_valid = false;
    }

    if (!config) {
        return false;
    }

    seesaw_init_bus(config);

    for (int retries = 0; retries < 10; ++retries) {
        uint8_t probe = 0;
        int rc = i2c_write_timeout_us(
            i2c0,
            config->seesaw_i2c_address,
            &probe,
            1,
            false,
            SEESAW_I2C_TIMEOUT_US
        );
        if (rc == 1) {
            found = true;
            break;
        }
        sleep_ms(10);
    }

    if (!found) {
        return false;
    }

    if (reset) {
        found = false;
        if (!seesaw_write8(config, SEESAW_STATUS_BASE, SEESAW_STATUS_SWRST, 0xFFu)) {
            return false;
        }
        for (int retries = 0; retries < 10; ++retries) {
            uint8_t probe = 0;
            int rc = i2c_write_timeout_us(
                i2c0,
                config->seesaw_i2c_address,
                &probe,
                1,
                false,
                SEESAW_I2C_TIMEOUT_US
            );
            if (rc == 1) {
                found = true;
                break;
            }
            sleep_ms(10);
        }
        if (!found) {
            return false;
        }
    }

    found = false;
    for (int retries = 0; retries < 10; ++retries) {
        if (seesaw_read(config, SEESAW_STATUS_BASE, SEESAW_STATUS_HW_ID, &hw_id, 1, 10000u) &&
            seesaw_hw_id_supported_adafruit(hw_id)) {
            found = true;
            break;
        }
        sleep_ms(10);
    }

    if (!found) {
        if (info && seesaw_read(config, SEESAW_STATUS_BASE, SEESAW_STATUS_HW_ID, &hw_id, 1, 10000u)) {
            info->hw_id = hw_id;
        }
        return false;
    }

    if (info) {
        info->hw_id = hw_id;
        if (seesaw_read(config, SEESAW_STATUS_BASE, SEESAW_STATUS_VERSION,
                        version_buf, sizeof(version_buf), 10000u)) {
            info->version = ((uint32_t)version_buf[0] << 24) |
                            ((uint32_t)version_buf[1] << 16) |
                            ((uint32_t)version_buf[2] << 8) |
                            (uint32_t)version_buf[3];
            info->version_valid = true;
        }
    }

    return seesaw_hw_id_present(hw_id);
}

bool seesaw_begin(const node_config_t *config, seesaw_device_info_t *info) {
    return seesaw_begin_adafruit(config, info, true);
}

bool seesaw_touch_read(const node_config_t *config, uint16_t *raw_out) {
    uint8_t buf[2] = {0};

    if (!config || !raw_out) {
        return false;
    }

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
