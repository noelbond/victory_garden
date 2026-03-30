#include "config.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "hardware/flash.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"

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

static bool extract_json_string(const char *payload, const char *key, char *out, size_t out_size) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char *start = strstr(payload, pattern);
    if (!start) {
        return false;
    }
    start += strlen(pattern);
    const char *end = strchr(start, '"');
    if (!end) {
        return false;
    }
    size_t copy_len = (size_t)(end - start);
    if (copy_len >= out_size) {
        copy_len = out_size - 1;
    }
    memcpy(out, start, copy_len);
    out[copy_len] = '\0';
    return true;
}

static bool extract_json_bool(const char *payload, const char *key, bool *out) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *start = strstr(payload, pattern);
    if (!start) {
        return false;
    }
    start += strlen(pattern);
    if (strncmp(start, "true", 4) == 0) {
        *out = true;
        return true;
    }
    if (strncmp(start, "false", 5) == 0) {
        *out = false;
        return true;
    }
    return false;
}

static bool extract_json_int(const char *payload, const char *key, int *out) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *start = strstr(payload, pattern);
    if (!start) {
        return false;
    }
    start += strlen(pattern);
    *out = (int)strtol(start, NULL, 10);
    return true;
}

static bool extract_json_float(const char *payload, const char *key, float *out) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *start = strstr(payload, pattern);
    if (!start) {
        return false;
    }
    start += strlen(pattern);
    *out = strtof(start, NULL);
    return true;
}

void node_config_reset_defaults(node_config_t *config) {
    memset(config, 0, sizeof(*config));
    config->magic = VG_CONFIG_MAGIC;
    config->version = VG_CONFIG_VERSION;
    safe_copy(config->wifi_ssid, sizeof(config->wifi_ssid), VG_DEFAULT_WIFI_SSID);
    safe_copy(config->wifi_password, sizeof(config->wifi_password), VG_DEFAULT_WIFI_PASSWORD);
    safe_copy(config->mqtt_host, sizeof(config->mqtt_host), VG_DEFAULT_MQTT_HOST);
    config->mqtt_port = VG_DEFAULT_MQTT_PORT;
    safe_copy(config->node_id, sizeof(config->node_id), VG_DEFAULT_NODE_ID);
    config->assigned = true;
    safe_copy(config->zone_id, sizeof(config->zone_id), VG_DEFAULT_ZONE_ID);
    config->crop_id[0] = '\0';
    config->dry_threshold = 30.0f;
    config->max_pulse_runtime_sec = 45;
    config->daily_max_runtime_sec = 300;
    config->config_version[0] = '\0';
    config->publish_interval_ms = VG_DEFAULT_PUBLISH_INTERVAL_MS;
    config->moisture_adc_gpio = VG_DEFAULT_MOISTURE_ADC_GPIO;
    config->moisture_invert_percent = VG_DEFAULT_MOISTURE_INVERT_PERCENT;
    config->checksum = config_checksum(config);
}

void node_config_load(node_config_t *config) {
    const node_config_t *flash_config = (const node_config_t *)(XIP_BASE + VG_FLASH_CONFIG_OFFSET);
    if (flash_config->magic == VG_CONFIG_MAGIC &&
        flash_config->version == VG_CONFIG_VERSION &&
        flash_config->checksum == config_checksum(flash_config)) {
        memcpy(config, flash_config, sizeof(*config));
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
    }

    *config = updated;
    return true;
}
