#include "i2c_bus.h"

#include <hardware/gpio.h>
#include <hardware/i2c.h>

static bool g_i2c_bus_initialized = false;

void i2c_bus_init(const node_config_t *config) {
    if (g_i2c_bus_initialized || !config) {
        return;
    }

    // GP0/GP1 (this board's default ADS1115 SDA/SCL) mux to the I2C0
    // hardware block, not I2C1 — Pico GPIO-to-I2C mapping is `gpio % 4`:
    // 0/1 -> I2C0, 2/3 -> I2C1. If config_local.h overrides these pins to a
    // pair that muxes to I2C1 instead, this needs to switch to i2c1.
    i2c_init(i2c0, 100 * 1000);
    gpio_set_function(config->ads1115_i2c_sda_gpio, GPIO_FUNC_I2C);
    gpio_set_function(config->ads1115_i2c_scl_gpio, GPIO_FUNC_I2C);
    gpio_pull_up(config->ads1115_i2c_sda_gpio);
    gpio_pull_up(config->ads1115_i2c_scl_gpio);
    g_i2c_bus_initialized = true;
}
