#include "sht40.h"

#include <stddef.h>
#include <hardware/gpio.h>
#include <hardware/i2c.h>
#include <pico/stdlib.h>
#include <stdio.h>

#include "i2c_bus.h"

#define SHT40_I2C_ADDRESS 0x44u
#define SHT40_MEASURE_HIGH_PRECISION 0xFDu
#define SHT40_READ_SERIAL 0x89u
#define SHT40_I2C_TIMEOUT_US 50000u
#define SHT40_MEASURE_DELAY_MS 20u
#define SHT40_SERIAL_DELAY_MS 2u

static uint8_t crc8(const uint8_t *data, size_t length) {
    uint8_t crc = 0xFFu;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (uint8_t bit = 0; bit < 8u; ++bit) {
            crc = (crc & 0x80u) ? (uint8_t)((crc << 1) ^ 0x31u) : (uint8_t)(crc << 1);
        }
    }
    return crc;
}

bool sht40_probe(const node_config_t *config) {
    uint8_t command = SHT40_READ_SERIAL;
    uint8_t response[6] = {0};

    if (!config) {
        return false;
    }

    i2c_bus_init(config);
    if (i2c_write_timeout_us(i2c0, SHT40_I2C_ADDRESS, &command, 1, false, SHT40_I2C_TIMEOUT_US) != 1) {
        return false;
    }
    sleep_ms(SHT40_SERIAL_DELAY_MS);
    if (i2c_read_timeout_us(i2c0, SHT40_I2C_ADDRESS, response, sizeof(response), false, SHT40_I2C_TIMEOUT_US) != (int)sizeof(response)) {
        return false;
    }
    return crc8(response, 2) == response[2] && crc8(&response[3], 2) == response[5];
}

uint8_t sht40_scan_bus(const node_config_t *config) {
    uint8_t found = 0;
    bool sht40_found = false;
    bool ads1115_found = false;
    const uint8_t probe_byte = 0x00u;

    if (!config) {
        return 0;
    }

    i2c_bus_init(config);
    printf("[i2c] scanning i2c0 sda=GP%u scl=GP%u\n",
        (unsigned)config->ads1115_i2c_sda_gpio,
        (unsigned)config->ads1115_i2c_scl_gpio);

    for (uint8_t address = 0x08u; address <= 0x77u; ++address) {
        int rc = i2c_write_timeout_us(i2c0, address, &probe_byte, 1, false, SHT40_I2C_TIMEOUT_US);
        if (rc != 1) {
            continue;
        }

        printf("[i2c] device found at 0x%02X\n", (unsigned)address);
        found++;
        if (address == SHT40_I2C_ADDRESS) {
            sht40_found = true;
        }
        if (address == config->ads1115_i2c_address) {
            ads1115_found = true;
        }
    }

    if (!sht40_found && sht40_probe(config)) {
        printf("[i2c] device found at 0x%02X (sht40 protocol probe)\n", (unsigned)SHT40_I2C_ADDRESS);
        found++;
        sht40_found = true;
    }

    printf("[i2c] scan complete found=%u sht40=0x%02X:%s ads1115=0x%02X:%s\n",
        (unsigned)found,
        (unsigned)SHT40_I2C_ADDRESS,
        sht40_found ? "FOUND" : "MISSING",
        (unsigned)config->ads1115_i2c_address,
        ads1115_found ? "FOUND" : "MISSING");
    fflush(stdout);
    return found;
}

bool sht40_read(const node_config_t *config, float *temperature_c_out, float *humidity_percent_out) {
    uint8_t command = SHT40_MEASURE_HIGH_PRECISION;
    uint8_t response[6] = {0};

    if (!config || !temperature_c_out || !humidity_percent_out) {
        return false;
    }

    i2c_bus_init(config);
    if (i2c_write_timeout_us(i2c0, SHT40_I2C_ADDRESS, &command, 1, false, SHT40_I2C_TIMEOUT_US) != 1) {
        printf("[sht40] write failed addr=0x%02X\n", (unsigned)SHT40_I2C_ADDRESS);
        fflush(stdout);
        return false;
    }
    sleep_ms(SHT40_MEASURE_DELAY_MS);
    if (i2c_read_timeout_us(i2c0, SHT40_I2C_ADDRESS, response, sizeof(response), false, SHT40_I2C_TIMEOUT_US) != (int)sizeof(response)) {
        printf("[sht40] read failed addr=0x%02X\n", (unsigned)SHT40_I2C_ADDRESS);
        fflush(stdout);
        return false;
    }
    if (crc8(response, 2) != response[2] || crc8(&response[3], 2) != response[5]) {
        printf("[sht40] crc failed addr=0x%02X\n", (unsigned)SHT40_I2C_ADDRESS);
        fflush(stdout);
        return false;
    }

    uint16_t raw_temperature = (uint16_t)(((uint16_t)response[0] << 8) | response[1]);
    uint16_t raw_humidity = (uint16_t)(((uint16_t)response[3] << 8) | response[4]);
    *temperature_c_out = -45.0f + (175.0f * (float)raw_temperature / 65535.0f);
    *humidity_percent_out = -6.0f + (125.0f * (float)raw_humidity / 65535.0f);
    if (*humidity_percent_out < 0.0f) {
        *humidity_percent_out = 0.0f;
    } else if (*humidity_percent_out > 100.0f) {
        *humidity_percent_out = 100.0f;
    }
    printf("[sht40] read ok temp_c=%.2f humidity=%.2f\n",
        (double)*temperature_c_out,
        (double)*humidity_percent_out);
    fflush(stdout);
    return true;
}
