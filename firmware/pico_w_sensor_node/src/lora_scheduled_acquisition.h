#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "config.h"
#include "sensors.h"

// Acquisition is intentionally independent of LoRa framing and transport.
// Each soil result owns a fresh snapshot from this bounded scheduler slot.
typedef struct {
    bool configured;
    bool attempted;
    bool read_succeeded;
    sensor_snapshot_t snapshot;
} lora_soil_channel_result_t;

bool lora_scheduled_channel_configured(const node_config_t *config, uint8_t channel);
bool lora_acquire_environment(
    const node_config_t *config,
    float *temperature_c_out,
    float *humidity_percent_out
);
void lora_acquire_soil_channels(
    const node_config_t *config,
    float air_temperature_c,
    float humidity_percent,
    bool environment_valid,
    lora_soil_channel_result_t results[VG_ADS1115_CHANNEL_COUNT]
);
