#ifndef NODE_STORAGE_H
#define NODE_STORAGE_H

#include <Arduino.h>

constexpr uint32_t NODE_CONFIG_VERSION = 2;
constexpr size_t WIFI_SSID_MAX_LEN = 32;
constexpr size_t WIFI_PASSWORD_MAX_LEN = 63;
constexpr size_t MQTT_BROKER_MAX_LEN = 63;
constexpr size_t MQTT_USERNAME_MAX_LEN = 63;
constexpr size_t MQTT_PASSWORD_MAX_LEN = 63;
constexpr size_t NODE_ID_MAX_LEN = 31;
constexpr size_t ZONE_ID_MAX_LEN = 31;
constexpr size_t MQTT_CLIENT_ID_MAX_LEN = 31;
constexpr size_t CONFIG_VERSION_MAX_LEN = 31;
constexpr size_t CROP_ID_MAX_LEN = 31;
constexpr size_t CROP_NAME_MAX_LEN = 63;
constexpr size_t CLIMATE_PREFERENCE_MAX_LEN = 63;

struct NodeStoredConfig {
  uint32_t version;
  bool provisioned;
  bool assigned;
  char wifi_ssid[WIFI_SSID_MAX_LEN + 1];
  char wifi_password[WIFI_PASSWORD_MAX_LEN + 1];
  char mqtt_broker[MQTT_BROKER_MAX_LEN + 1];
  uint16_t mqtt_port;
  char mqtt_username[MQTT_USERNAME_MAX_LEN + 1];
  char mqtt_password[MQTT_PASSWORD_MAX_LEN + 1];
  char node_id[NODE_ID_MAX_LEN + 1];
  char zone_id[ZONE_ID_MAX_LEN + 1];
  char mqtt_client_id[MQTT_CLIENT_ID_MAX_LEN + 1];
  char config_version[CONFIG_VERSION_MAX_LEN + 1];
  bool zone_active;
  bool allowed_hours_enabled;
  uint8_t allowed_start_hour;
  uint8_t allowed_end_hour;
  char crop_id[CROP_ID_MAX_LEN + 1];
  char crop_name[CROP_NAME_MAX_LEN + 1];
  float dry_threshold;
  uint16_t max_pulse_runtime_sec;
  uint16_t daily_max_runtime_sec;
  char climate_preference[CLIMATE_PREFERENCE_MAX_LEN + 1];
  uint16_t time_to_harvest_days;
};

void setNodeConfigDefaults(NodeStoredConfig* config);
bool loadNodeConfig(NodeStoredConfig* config);
bool saveNodeConfig(const NodeStoredConfig& config);
bool clearNodeConfig();

#endif
