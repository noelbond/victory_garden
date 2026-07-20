#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "config.h"

bool ads1115_init(const node_config_t *config);
bool ads1115_read_channel(const node_config_t *config, uint8_t channel, uint16_t *raw_out);
