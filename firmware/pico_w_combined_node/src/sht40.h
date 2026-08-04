#pragma once

#include <stdbool.h>

#include "config.h"

bool sht40_probe(const node_config_t *config);
uint8_t sht40_scan_bus(const node_config_t *config);
bool sht40_read(const node_config_t *config, float *temperature_c_out, float *humidity_percent_out);
