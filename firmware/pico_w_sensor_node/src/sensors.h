#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "config.h"

typedef struct {
    uint16_t moisture_raw;
    int moisture_percent;
    bool healthy;
} sensor_snapshot_t;

void sensors_init(const node_config_t *config);
bool sensors_read(const node_config_t *config, sensor_snapshot_t *out);
