#pragma once

#include "config.h"

// Shared I2C0 bus initialization for the ADS1115 and SHT40 drivers, which sit
// on the same physical bus and pins. Safe to call from both; only the first
// call actually configures the bus.
void i2c_bus_init(const node_config_t *config);
