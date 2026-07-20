#include "i2c1_bus.h"

#include <hardware/gpio.h>
#include <hardware/i2c.h>

static bool g_i2c1_initialized = false;

void i2c1_bus_init(const node_config_t *config) {
    if (g_i2c1_initialized || !config) {
        return;
    }

    i2c_init(i2c1, 100 * 1000);
    gpio_set_function(config->ads1115_i2c_sda_gpio, GPIO_FUNC_I2C);
    gpio_set_function(config->ads1115_i2c_scl_gpio, GPIO_FUNC_I2C);
    gpio_pull_up(config->ads1115_i2c_sda_gpio);
    gpio_pull_up(config->ads1115_i2c_scl_gpio);
    g_i2c1_initialized = true;
}
