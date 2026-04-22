#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "config.h"

typedef struct {
    uint8_t hw_id;
    uint32_t version;
    bool version_valid;
} seesaw_device_info_t;

bool seesaw_begin_adafruit(const node_config_t *config, seesaw_device_info_t *info, bool reset);
bool seesaw_begin(const node_config_t *config, seesaw_device_info_t *info);
bool seesaw_touch_read(const node_config_t *config, uint16_t *raw_out);
