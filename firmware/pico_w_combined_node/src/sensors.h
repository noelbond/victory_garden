#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "config.h"

typedef struct {
    uint16_t moisture_raw;
    int moisture_percent;
    float air_temperature_c;
    float humidity_percent;
    bool environment_valid;
    bool soil_moisture_read;
    bool healthy;
} sensor_snapshot_t;

void sensors_init(const node_config_t *config);
bool sensors_read(const node_config_t *config, uint8_t channel, sensor_snapshot_t *out);
