#include "config.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "hardware/flash.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"

#include "json_lite.h"

static uint32_t config_checksum(const node_config_t *config) {
    const uint8_t *bytes = (const uint8_t *)config;
    uint32_t hash = 2166136261u;

    for (size_t i = 0; i < sizeof(node_config_t); ++i) {
        if (i >= offsetof(node_config_t, checksum) && i < offsetof(node_config_t, checksum) + sizeof(config->checksum)) {
            continue;
        }
        hash ^= bytes[i];
        hash *= 16777619u;
    }
    return hash;
}

static void safe_copy(char *dst, size_t dst_size, const char *src) {
    if (!dst || dst_size == 0) {
        return;
    }
    snprintf(dst, dst_size, "%s", src ? src : "");
}

static void set_error(char *error, size_t error_size, const char *message) {
    if (error && error_size > 0) {
        snprintf(error, error_size, "%s", message);
    }
}

static bool string_is_placeholder(const char *value) {
    return value && strncmp(value, "CHANGE_ME_", 10) == 0;
}

static bool should_prefer_default_broker_bundle(const node_config_t *config) {
    if (!config) {
        return false;
    }

    return string_is_placeholder(config->mqtt_host) &&
           !string_is_placeholder(VG_DEFAULT_MQTT_HOST);
}

static void safe_copy_channel_node_id(node_config_t *config, uint8_t channel, const char *node_id) {
    if (!config || channel >= VG_ADS1115_CHANNEL_COUNT) {
        return;
    }
    safe_copy(config->channel_node_id[channel], sizeof(config->channel_node_id[channel]), node_id);
}

static void set_default_channel_config(node_config_t *config) {
    static const char *default_node_ids[VG_ADS1115_CHANNEL_COUNT] = {
        VG_DEFAULT_CHANNEL0_NODE_ID,
        VG_DEFAULT_CHANNEL1_NODE_ID,
        VG_DEFAULT_CHANNEL2_NODE_ID,
        VG_DEFAULT_CHANNEL3_NODE_ID,
    };
    static const uint16_t default_dry[VG_ADS1115_CHANNEL_COUNT] = {
        VG_DEFAULT_CHANNEL0_MOISTURE_RAW_DRY,
        VG_DEFAULT_CHANNEL1_MOISTURE_RAW_DRY,
        VG_DEFAULT_CHANNEL2_MOISTURE_RAW_DRY,
        VG_DEFAULT_CHANNEL3_MOISTURE_RAW_DRY,
    };
    static const uint16_t default_wet[VG_ADS1115_CHANNEL_COUNT] = {
        VG_DEFAULT_CHANNEL0_MOISTURE_RAW_WET,
        VG_DEFAULT_CHANNEL1_MOISTURE_RAW_WET,
        VG_DEFAULT_CHANNEL2_MOISTURE_RAW_WET,
        VG_DEFAULT_CHANNEL3_MOISTURE_RAW_WET,
    };

    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        safe_copy_channel_node_id(config, channel, default_node_ids[channel]);
        config->channel_moisture_raw_dry[channel] = default_dry[channel];
        config->channel_moisture_raw_wet[channel] = default_wet[channel];
    }
}

static void generate_channel_node_ids(node_config_t *config) {
    if (!config) {
        return;
    }

    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        snprintf(config->channel_node_id[channel],
                 sizeof(config->channel_node_id[channel]),
                 "%s-ch%u",
                 config->node_id,
                 (unsigned)channel);
    }
}

static bool parse_channel_calibration(const char *object, uint16_t *dry_out, uint16_t *wet_out, bool *has_calibration_out) {
    int dry = 0;
    int wet = 0;
    bool has_dry = extract_json_int(object, "moisture_raw_dry", &dry);
    bool has_wet = extract_json_int(object, "moisture_raw_wet", &wet);

    *has_calibration_out = false;
    if (has_dry != has_wet) {
        return false;
    }
    if (!has_dry) {
        return true;
    }
    if (dry < 0 || dry > 65535 || wet < 0 || wet > 65535 || dry == wet) {
        return false;
    }

    *dry_out = (uint16_t)dry;
    *wet_out = (uint16_t)wet;
    *has_calibration_out = true;
    return true;
}

static bool apply_channels_json(node_config_t *config, const char *payload, bool require_node_ids, char *error, size_t error_size) {
    const char *cursor = NULL;
    char object[512];

    if (!extract_json_array_start(payload, "channels", &cursor)) {
        return false;
    }

    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        if (!next_json_object(&cursor, object, sizeof(object))) {
            set_error(error, error_size, "channels array has too few entries");
            return false;
        }

        char node_id[VG_MAX_NODE_ID_LEN] = {0};
        uint16_t dry = 0;
        uint16_t wet = 0;
        bool has_calibration = false;
        bool has_node_id = extract_json_string(object, "node_id", node_id, sizeof(node_id));

        if (require_node_ids && (!has_node_id || node_id[0] == '\0')) {
            set_error(error, error_size, "channel node_id missing");
            return false;
        }
        if (has_node_id && node_id[0] != '\0') {
            safe_copy_channel_node_id(config, channel, node_id);
        }

        if (!parse_channel_calibration(object, &dry, &wet, &has_calibration)) {
            set_error(error, error_size, "invalid channel moisture calibration");
            return false;
        }
        if (has_calibration) {
            config->channel_moisture_raw_dry[channel] = dry;
            config->channel_moisture_raw_wet[channel] = wet;
        }
    }

    return true;
}

static bool has_channels_json(const char *payload) {
    const char *cursor = NULL;
    return extract_json_array_start(payload, "channels", &cursor);
}

static bool utc_offset_hours_valid(int value) {
    return value >= -12 && value <= 14;
}

void node_config_reset_defaults(node_config_t *config) {
    memset(config, 0, sizeof(*config));
    config->magic = VG_CONFIG_MAGIC;
    config->version = VG_CONFIG_VERSION;
    safe_copy(config->wifi_ssid, sizeof(config->wifi_ssid), VG_DEFAULT_WIFI_SSID);
    safe_copy(config->wifi_password, sizeof(config->wifi_password), VG_DEFAULT_WIFI_PASSWORD);
    safe_copy(config->mqtt_host, sizeof(config->mqtt_host), VG_DEFAULT_MQTT_HOST);
    config->mqtt_port = VG_DEFAULT_MQTT_PORT;
    safe_copy(config->mqtt_username, sizeof(config->mqtt_username), VG_DEFAULT_MQTT_USERNAME);
    safe_copy(config->mqtt_password, sizeof(config->mqtt_password), VG_DEFAULT_MQTT_PASSWORD);
    safe_copy(config->node_id, sizeof(config->node_id), VG_DEFAULT_NODE_ID);
    config->assigned = true;
    safe_copy(config->zone_id, sizeof(config->zone_id), VG_DEFAULT_ZONE_ID);
    config->crop_id[0] = '\0';
    config->dry_threshold = 30.0f;
    config->max_pulse_runtime_sec = 45;
    config->daily_max_runtime_sec = 300;
    config->config_version[0] = '\0';
    config->publish_interval_ms = VG_DEFAULT_PUBLISH_INTERVAL_MS;
    config->utc_offset_hours = (int8_t)VG_DEFAULT_UTC_OFFSET_HOURS;
    config->ads1115_i2c_sda_gpio = VG_DEFAULT_ADS1115_I2C_SDA_GPIO;
    config->ads1115_i2c_scl_gpio = VG_DEFAULT_ADS1115_I2C_SCL_GPIO;
    config->ads1115_i2c_address = VG_DEFAULT_ADS1115_I2C_ADDRESS;
    set_default_channel_config(config);
    config->actuator_relay_gpio = VG_DEFAULT_ACTUATOR_RELAY_GPIO;
    config->actuator_relay_active_high = VG_DEFAULT_ACTUATOR_RELAY_ACTIVE_HIGH;
    config->checksum = config_checksum(config);
}

void node_config_load(node_config_t *config) {
    if (VG_FORCE_DEFAULT_CONFIG) {
        node_config_reset_defaults(config);
        return;
    }

    const node_config_t *flash_config = (const node_config_t *)(XIP_BASE + VG_FLASH_CONFIG_OFFSET);
    if (flash_config->magic == VG_CONFIG_MAGIC &&
        flash_config->version == VG_CONFIG_VERSION &&
        flash_config->checksum == config_checksum(flash_config)) {
        memcpy(config, flash_config, sizeof(*config));
        if (should_prefer_default_broker_bundle(config)) {
            safe_copy(config->mqtt_host, sizeof(config->mqtt_host), VG_DEFAULT_MQTT_HOST);
            config->mqtt_port = VG_DEFAULT_MQTT_PORT;
            safe_copy(config->mqtt_username, sizeof(config->mqtt_username), VG_DEFAULT_MQTT_USERNAME);
            safe_copy(config->mqtt_password, sizeof(config->mqtt_password), VG_DEFAULT_MQTT_PASSWORD);
        }
        return;
    }
    node_config_reset_defaults(config);
}

bool node_config_save(const node_config_t *config, char *error, size_t error_size) {
    node_config_t copy = *config;
    copy.magic = VG_CONFIG_MAGIC;
    copy.version = VG_CONFIG_VERSION;
    copy.checksum = config_checksum(&copy);

    uint8_t sector[FLASH_SECTOR_SIZE];
    memset(sector, 0xFF, sizeof(sector));
    memcpy(sector, &copy, sizeof(copy));

    uint32_t ints = save_and_disable_interrupts();
    flash_range_erase(VG_FLASH_CONFIG_OFFSET, FLASH_SECTOR_SIZE);
    flash_range_program(VG_FLASH_CONFIG_OFFSET, sector, FLASH_SECTOR_SIZE);
    restore_interrupts(ints);

    const node_config_t *written = (const node_config_t *)(XIP_BASE + VG_FLASH_CONFIG_OFFSET);
    if (written->checksum != copy.checksum) {
        set_error(error, error_size, "flash verify failed");
        return false;
    }
    return true;
}

bool node_config_requires_provisioning(const node_config_t *config) {
    if (!config) {
        return true;
    }

    return config->wifi_ssid[0] == '\0' ||
           config->wifi_password[0] == '\0' ||
           config->mqtt_host[0] == '\0' ||
           config->node_id[0] == '\0' ||
           config->zone_id[0] == '\0' ||
           string_is_placeholder(config->wifi_ssid) ||
           string_is_placeholder(config->wifi_password);
}

bool node_config_apply_provision_json(node_config_t *config, const char *payload, char *error, size_t error_size) {
    if (!config || !payload) {
        set_error(error, error_size, "missing provisioning payload");
        return false;
    }

    node_config_t updated = *config;
    char wifi_ssid[VG_MAX_SSID_LEN] = {0};
    char wifi_password[VG_MAX_PASSWORD_LEN] = {0};
    char mqtt_host[VG_MAX_HOST_LEN] = {0};
    char mqtt_username[VG_MAX_MQTT_USERNAME_LEN] = {0};
    char mqtt_password[VG_MAX_MQTT_PASSWORD_LEN] = {0};
    char node_id[VG_MAX_NODE_ID_LEN] = {0};
    char zone_id[VG_MAX_ZONE_ID_LEN] = {0};
    int mqtt_port = 0;
    int publish_interval_ms = 0;
    int utc_offset_hours = 0;

    if (!extract_json_string(payload, "wifi_ssid", wifi_ssid, sizeof(wifi_ssid)) ||
        !extract_json_string(payload, "wifi_password", wifi_password, sizeof(wifi_password)) ||
        !extract_json_string(payload, "mqtt_host", mqtt_host, sizeof(mqtt_host)) ||
        !extract_json_string(payload, "node_id", node_id, sizeof(node_id)) ||
        !extract_json_string(payload, "zone_id", zone_id, sizeof(zone_id)) ||
        !extract_json_int(payload, "mqtt_port", &mqtt_port)) {
        set_error(error, error_size, "required provisioning fields missing");
        return false;
    }

    extract_json_string(payload, "mqtt_username", mqtt_username, sizeof(mqtt_username));
    extract_json_string(payload, "mqtt_password", mqtt_password, sizeof(mqtt_password));

    if (wifi_ssid[0] == '\0' || wifi_password[0] == '\0' || mqtt_host[0] == '\0' ||
        node_id[0] == '\0' || zone_id[0] == '\0') {
        set_error(error, error_size, "provisioning fields cannot be blank");
        return false;
    }

    if (mqtt_port <= 0 || mqtt_port > 65535) {
        set_error(error, error_size, "invalid mqtt_port");
        return false;
    }

    safe_copy(updated.wifi_ssid, sizeof(updated.wifi_ssid), wifi_ssid);
    safe_copy(updated.wifi_password, sizeof(updated.wifi_password), wifi_password);
    safe_copy(updated.mqtt_host, sizeof(updated.mqtt_host), mqtt_host);
    safe_copy(updated.mqtt_username, sizeof(updated.mqtt_username), mqtt_username);
    safe_copy(updated.mqtt_password, sizeof(updated.mqtt_password), mqtt_password);
    safe_copy(updated.node_id, sizeof(updated.node_id), node_id);
    safe_copy(updated.zone_id, sizeof(updated.zone_id), zone_id);
    updated.mqtt_port = (uint16_t)mqtt_port;
    updated.assigned = true;

    if (extract_json_int(payload, "publish_interval_ms", &publish_interval_ms) && publish_interval_ms > 0) {
        updated.publish_interval_ms = (uint32_t)publish_interval_ms;
    }
    if (extract_json_int(payload, "utc_offset_hours", &utc_offset_hours)) {
        if (!utc_offset_hours_valid(utc_offset_hours)) {
            set_error(error, error_size, "invalid utc_offset_hours");
            return false;
        }
        updated.utc_offset_hours = (int8_t)utc_offset_hours;
    }

    if (has_channels_json(payload)) {
        if (!apply_channels_json(&updated, payload, true, error, error_size)) {
            return false;
        }
    } else {
        generate_channel_node_ids(&updated);
    }

    *config = updated;
    return true;
}

bool node_config_apply_json(
    node_config_t *config,
    const char *payload,
    bool *zone_changed,
    char *error,
    size_t error_size
) {
    if (zone_changed) {
        *zone_changed = false;
    }
    if (!payload) {
        set_error(error, error_size, "empty config payload");
        return false;
    }

    node_config_t updated = *config;
    bool assigned = false;
    char config_version[VG_MAX_CONFIG_VERSION_LEN] = {0};
    char node_id[VG_MAX_NODE_ID_LEN] = {0};

    if (!extract_json_bool(payload, "assigned", &assigned)) {
        set_error(error, error_size, "assigned missing");
        return false;
    }
    if (!extract_json_string(payload, "config_version", config_version, sizeof(config_version))) {
        set_error(error, error_size, "config_version missing");
        return false;
    }
    if (!extract_json_string(payload, "node_id", node_id, sizeof(node_id))) {
        set_error(error, error_size, "node_id missing");
        return false;
    }
    if (strcmp(node_id, config->node_id) != 0) {
        set_error(error, error_size, "node_id mismatch");
        return false;
    }

    updated.assigned = assigned;
    safe_copy(updated.config_version, sizeof(updated.config_version), config_version);

    if (!assigned) {
        int utc_offset_hours = 0;
        if (extract_json_int(payload, "utc_offset_hours", &utc_offset_hours)) {
            if (!utc_offset_hours_valid(utc_offset_hours)) {
                set_error(error, error_size, "invalid utc_offset_hours");
                return false;
            }
            updated.utc_offset_hours = (int8_t)utc_offset_hours;
        }
        if (zone_changed && strcmp(updated.zone_id, "unassigned") != 0) {
            *zone_changed = true;
        }
        safe_copy(updated.zone_id, sizeof(updated.zone_id), "unassigned");
        updated.crop_id[0] = '\0';
        updated.dry_threshold = 0.0f;
        updated.max_pulse_runtime_sec = 0;
        updated.daily_max_runtime_sec = 0;
    } else {
        char zone_id[VG_MAX_ZONE_ID_LEN] = {0};
        char crop_id[VG_MAX_CROP_ID_LEN] = {0};
        float dry_threshold = 0.0f;
        int max_pulse = 0;
        int daily_max = 0;
        int publish_interval_ms = 0;
        int utc_offset_hours = 0;

        if (!extract_json_string(payload, "zone_id", zone_id, sizeof(zone_id)) ||
            !extract_json_string(payload, "crop_id", crop_id, sizeof(crop_id)) ||
            !extract_json_float(payload, "dry_threshold", &dry_threshold) ||
            !extract_json_int(payload, "max_pulse_runtime_sec", &max_pulse) ||
            !extract_json_int(payload, "daily_max_runtime_sec", &daily_max)) {
            set_error(error, error_size, "required config fields missing");
            return false;
        }

        if (dry_threshold <= 0.0f || max_pulse <= 0 || daily_max <= 0) {
            set_error(error, error_size, "invalid numeric config values");
            return false;
        }

        if (zone_changed && strcmp(updated.zone_id, zone_id) != 0) {
            *zone_changed = true;
        }
        safe_copy(updated.zone_id, sizeof(updated.zone_id), zone_id);
        safe_copy(updated.crop_id, sizeof(updated.crop_id), crop_id);
        updated.dry_threshold = dry_threshold;
        updated.max_pulse_runtime_sec = (uint16_t)max_pulse;
        updated.daily_max_runtime_sec = (uint16_t)daily_max;

        if (extract_json_int(payload, "publish_interval_ms", &publish_interval_ms) && publish_interval_ms > 0) {
            updated.publish_interval_ms = (uint32_t)publish_interval_ms;
        }
        if (extract_json_int(payload, "utc_offset_hours", &utc_offset_hours)) {
            if (!utc_offset_hours_valid(utc_offset_hours)) {
                set_error(error, error_size, "invalid utc_offset_hours");
                return false;
            }
            updated.utc_offset_hours = (int8_t)utc_offset_hours;
        }

        if (has_channels_json(payload) && !apply_channels_json(&updated, payload, false, error, error_size)) {
            return false;
        }
    }

    *config = updated;
    return true;
}
