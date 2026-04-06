#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "hardware/flash.h"

#ifndef __has_include
#define __has_include(x) 0
#endif

#if __has_include("config_local.h")
#include "config_local.h"
#endif

#define VG_CONFIG_MAGIC 0x56474131u
#define VG_CONFIG_VERSION 1u

#define VG_MAX_SSID_LEN 64
#define VG_MAX_PASSWORD_LEN 64
#define VG_MAX_HOST_LEN 64
#define VG_MAX_MQTT_USERNAME_LEN 64
#define VG_MAX_MQTT_PASSWORD_LEN 160
#define VG_MAX_NODE_ID_LEN 32
#define VG_MAX_ZONE_ID_LEN 32
#define VG_MAX_CROP_ID_LEN 32
#define VG_MAX_CONFIG_VERSION_LEN 40

#ifndef VG_DEFAULT_WIFI_SSID
#define VG_DEFAULT_WIFI_SSID "CHANGE_ME_SSID"
#endif

#ifndef VG_DEFAULT_WIFI_PASSWORD
#define VG_DEFAULT_WIFI_PASSWORD "CHANGE_ME_PASSWORD"
#endif

#ifndef VG_DEFAULT_MQTT_HOST
#define VG_DEFAULT_MQTT_HOST "192.168.4.41"
#endif

#ifndef VG_DEFAULT_MQTT_PORT
#define VG_DEFAULT_MQTT_PORT 1883
#endif

#ifndef VG_DEFAULT_MQTT_USERNAME
#define VG_DEFAULT_MQTT_USERNAME ""
#endif

#ifndef VG_DEFAULT_MQTT_PASSWORD
#define VG_DEFAULT_MQTT_PASSWORD ""
#endif

#ifndef VG_DEFAULT_NTP_SERVER
#define VG_DEFAULT_NTP_SERVER "pool.ntp.org"
#endif

#ifndef VG_DEFAULT_NODE_ID
#define VG_DEFAULT_NODE_ID "pico-w-actuator-zone1"
#endif

#ifndef VG_DEFAULT_ZONE_ID
#define VG_DEFAULT_ZONE_ID "zone1"
#endif

#ifndef VG_DEFAULT_PUBLISH_INTERVAL_MS
#define VG_DEFAULT_PUBLISH_INTERVAL_MS 60000u
#endif

#ifndef VG_DEFAULT_SEESAW_I2C_SDA_GPIO
#define VG_DEFAULT_SEESAW_I2C_SDA_GPIO 4u
#endif

#ifndef VG_DEFAULT_MOISTURE_RAW_DRY
#define VG_DEFAULT_MOISTURE_RAW_DRY 0u
#endif

#ifndef VG_DEFAULT_MOISTURE_RAW_WET
#define VG_DEFAULT_MOISTURE_RAW_WET 0u
#endif

#ifndef VG_DEFAULT_SEESAW_I2C_SCL_GPIO
#define VG_DEFAULT_SEESAW_I2C_SCL_GPIO 5u
#endif

#ifndef VG_DEFAULT_SEESAW_I2C_ADDRESS
#define VG_DEFAULT_SEESAW_I2C_ADDRESS 0x36u
#endif

#ifndef VG_DEFAULT_SEESAW_TOUCH_CHANNEL
#define VG_DEFAULT_SEESAW_TOUCH_CHANNEL 0u
#endif

#ifndef VG_DEFAULT_ACTUATOR_RELAY_GPIO
#define VG_DEFAULT_ACTUATOR_RELAY_GPIO 15u
#endif

#ifndef VG_DEFAULT_ACTUATOR_RELAY_ACTIVE_HIGH
#define VG_DEFAULT_ACTUATOR_RELAY_ACTIVE_HIGH true
#endif

#define VG_FLASH_CONFIG_OFFSET (PICO_FLASH_SIZE_BYTES - FLASH_SECTOR_SIZE)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t checksum;
    char wifi_ssid[VG_MAX_SSID_LEN];
    char wifi_password[VG_MAX_PASSWORD_LEN];
    char mqtt_host[VG_MAX_HOST_LEN];
    uint16_t mqtt_port;
    char mqtt_username[VG_MAX_MQTT_USERNAME_LEN];
    char mqtt_password[VG_MAX_MQTT_PASSWORD_LEN];
    char node_id[VG_MAX_NODE_ID_LEN];
    bool assigned;
    char zone_id[VG_MAX_ZONE_ID_LEN];
    char crop_id[VG_MAX_CROP_ID_LEN];
    float dry_threshold;
    uint16_t max_pulse_runtime_sec;
    uint16_t daily_max_runtime_sec;
    char config_version[VG_MAX_CONFIG_VERSION_LEN];
    uint32_t publish_interval_ms;
    uint16_t moisture_raw_dry;
    uint16_t moisture_raw_wet;
    uint8_t seesaw_i2c_sda_gpio;
    uint8_t seesaw_i2c_scl_gpio;
    uint8_t seesaw_i2c_address;
    uint8_t seesaw_touch_channel;
    uint8_t actuator_relay_gpio;
    bool actuator_relay_active_high;
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
