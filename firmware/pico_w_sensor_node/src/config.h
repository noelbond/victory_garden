#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "hardware/flash.h"

#define VG_CONFIG_MAGIC 0x56474E31u
#define VG_CONFIG_VERSION 4u

#define VG_MAX_SSID_LEN 64
#define VG_MAX_PASSWORD_LEN 64
#define VG_MAX_HOST_LEN 64
#define VG_MAX_NODE_ID_LEN 32
#define VG_MAX_ZONE_ID_LEN 32
#define VG_MAX_CROP_ID_LEN 32
#define VG_MAX_CONFIG_VERSION_LEN 40

#define VG_DEFAULT_WIFI_SSID "mywifi"
#define VG_DEFAULT_WIFI_PASSWORD "njbond36"
#define VG_DEFAULT_MQTT_HOST "192.168.4.41"
#define VG_DEFAULT_MQTT_PORT 1883
#define VG_DEFAULT_NODE_ID "pico-w-zone1"
#define VG_DEFAULT_ZONE_ID "zone1"
#define VG_DEFAULT_PUBLISH_INTERVAL_MS 60000u
#define VG_DEFAULT_MOISTURE_ADC_GPIO 26u
#define VG_DEFAULT_MOISTURE_INVERT_PERCENT true

#define VG_FLASH_CONFIG_OFFSET (PICO_FLASH_SIZE_BYTES - FLASH_SECTOR_SIZE)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t checksum;
    char wifi_ssid[VG_MAX_SSID_LEN];
    char wifi_password[VG_MAX_PASSWORD_LEN];
    char mqtt_host[VG_MAX_HOST_LEN];
    uint16_t mqtt_port;
    char node_id[VG_MAX_NODE_ID_LEN];
    bool assigned;
    char zone_id[VG_MAX_ZONE_ID_LEN];
    char crop_id[VG_MAX_CROP_ID_LEN];
    float dry_threshold;
    uint16_t max_pulse_runtime_sec;
    uint16_t daily_max_runtime_sec;
    char config_version[VG_MAX_CONFIG_VERSION_LEN];
    uint32_t publish_interval_ms;
    uint8_t moisture_adc_gpio;
    bool moisture_invert_percent;
} node_config_t;

void node_config_load(node_config_t *config);
bool node_config_save(const node_config_t *config, char *error, size_t error_size);
void node_config_reset_defaults(node_config_t *config);
bool node_config_apply_json(
    node_config_t *config,
    const char *payload,
    bool *zone_changed,
    char *error,
    size_t error_size
);
