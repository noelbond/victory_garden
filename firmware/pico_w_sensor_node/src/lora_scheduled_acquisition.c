#include "lora_scheduled_acquisition.h"

#include <string.h>

#include "sht40.h"

bool lora_scheduled_channel_configured(const node_config_t *config, uint8_t channel) {
    return config && channel < VG_ADS1115_CHANNEL_COUNT &&
        config->channel_node_id[channel][0] != '\0';
}

bool lora_acquire_environment(
    const node_config_t *config,
    float *temperature_c_out,
    float *humidity_percent_out
) {
    if (!config || !temperature_c_out || !humidity_percent_out) {
        return false;
    }
    return sht40_read(config, temperature_c_out, humidity_percent_out);
}

void lora_acquire_soil_channels(
    const node_config_t *config,
    float air_temperature_c,
    float humidity_percent,
    bool environment_valid,
    lora_soil_channel_result_t results[VG_ADS1115_CHANNEL_COUNT]
) {
    if (!results) {
        return;
    }

    memset(results, 0, sizeof(lora_soil_channel_result_t) * VG_ADS1115_CHANNEL_COUNT);
    if (!config) {
        return;
    }

    // One driver initialization is shared by this bounded all-channel slot.
    sensors_init(config);
    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        lora_soil_channel_result_t *result = &results[channel];
        result->configured = lora_scheduled_channel_configured(config, channel);
        if (!result->configured) {
            continue;
        }

        result->attempted = true;
        result->snapshot.air_temperature_c = air_temperature_c;
        result->snapshot.humidity_percent = humidity_percent;
        result->snapshot.environment_valid = environment_valid;
        result->snapshot.healthy = environment_valid;
        result->snapshot.soil_moisture_read = sensors_read(config, channel, &result->snapshot);
        result->read_succeeded = result->snapshot.soil_moisture_read;
        if (!result->read_succeeded) {
            result->snapshot.healthy = false;
        }
    }
}
