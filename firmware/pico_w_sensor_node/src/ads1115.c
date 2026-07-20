#include "ads1115.h"

#include <hardware/gpio.h>
#include <hardware/i2c.h>
#include <pico/stdlib.h>
#include <stdio.h>

#include "i2c1_bus.h"

#define ADS1115_REG_CONVERSION 0x00u
#define ADS1115_REG_CONFIG 0x01u
#define ADS1115_I2C_TIMEOUT_US 50000u
#define ADS1115_CONVERSION_TIMEOUT_MS 20u

static bool ads1115_write_register(const node_config_t *config, uint8_t reg, uint16_t value) {
    uint8_t buf[3] = {
        reg,
        (uint8_t)(value >> 8),
        (uint8_t)(value & 0xFFu),
    };

    if (!config) {
        return false;
    }

    return i2c_write_timeout_us(
        i2c1,
        config->ads1115_i2c_address,
        buf,
        sizeof(buf),
        false,
        ADS1115_I2C_TIMEOUT_US
    ) == (int)sizeof(buf);
}

static bool ads1115_read_register(const node_config_t *config, uint8_t reg, uint16_t *value_out) {
    uint8_t buf[2] = {0};

    if (!config || !value_out) {
        return false;
    }

    int write_rc = i2c_write_timeout_us(
        i2c1,
        config->ads1115_i2c_address,
        &reg,
        1,
        true,
        ADS1115_I2C_TIMEOUT_US
    );
    if (write_rc != 1) {
        return false;
    }

    int read_rc = i2c_read_timeout_us(
        i2c1,
        config->ads1115_i2c_address,
        buf,
        sizeof(buf),
        false,
        ADS1115_I2C_TIMEOUT_US
    );
    if (read_rc != (int)sizeof(buf)) {
        return false;
    }

    *value_out = (uint16_t)(((uint16_t)buf[0] << 8) | buf[1]);
    return true;
}

bool ads1115_init(const node_config_t *config) {
    if (!config) {
        return false;
    }

    i2c1_bus_init(config);

    uint16_t config_reg = 0;
    return ads1115_read_register(config, ADS1115_REG_CONFIG, &config_reg);
}

bool ads1115_read_channel(const node_config_t *config, uint8_t channel, uint16_t *raw_out) {
    if (!config || !raw_out || channel >= VG_ADS1115_CHANNEL_COUNT) {
        return false;
    }

    i2c1_bus_init(config);

    uint16_t config_value =
        (uint16_t)(0x8000u |                         // OS: start single conversion
                   ((uint16_t)(0x04u + channel) << 12) | // MUX: AINn vs GND
                   (0x01u << 9) |                    // PGA: +/-4.096V
                   (0x01u << 8) |                    // MODE: single-shot
                   (0x04u << 5) |                    // DR: 128 SPS
                   0x0003u);                         // QUE: disable comparator

    if (!ads1115_write_register(config, ADS1115_REG_CONFIG, config_value)) {
        return false;
    }

    absolute_time_t deadline = make_timeout_time_ms(ADS1115_CONVERSION_TIMEOUT_MS);
    uint16_t polled_config = 0;
    do {
        if (!ads1115_read_register(config, ADS1115_REG_CONFIG, &polled_config)) {
            return false;
        }
        if ((polled_config & 0x8000u) != 0) {
            uint16_t raw = 0;
            if (!ads1115_read_register(config, ADS1115_REG_CONVERSION, &raw)) {
                return false;
            }
            *raw_out = (uint16_t)((int16_t)raw);
            return true;
        }
        sleep_ms(1);
    } while (absolute_time_diff_us(get_absolute_time(), deadline) > 0);

    return false;
}
