#include "sensors.h"

#include <hardware/adc.h>

static int adc_input_from_gpio(uint gpio) {
    return (int)gpio - 26;
}

void sensors_init(const node_config_t *config) {
    adc_init();
    adc_gpio_init(config->moisture_adc_gpio);
}

bool sensors_read(const node_config_t *config, sensor_snapshot_t *out) {
    if (!out || config->moisture_adc_gpio < 26 || config->moisture_adc_gpio > 28) {
        return false;
    }

    adc_select_input((uint)adc_input_from_gpio(config->moisture_adc_gpio));
    uint16_t raw = adc_read();

    int percent = (int)((raw * 100u) / 4095u);
    if (config->moisture_invert_percent) {
        percent = 100 - percent;
    }
    if (percent < 0) {
        percent = 0;
    } else if (percent > 100) {
        percent = 100;
    }

    out->moisture_raw = raw;
    out->moisture_percent = percent;
    out->healthy = !(raw == 0 || raw >= 4095);
    return true;
}
