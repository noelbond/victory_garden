#include "node_storage.h"

#include <FlashStorage.h>

#include "node_config.h"

struct StoredNodeConfigRecord {
  NodeStoredConfig config;
  uint32_t checksum;
};

FlashStorage(nodeConfigStorage, StoredNodeConfigRecord);

static uint32_t checksumConfig(const NodeStoredConfig& config) {
  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&config);
  uint32_t checksum = 5381UL;

  for (size_t i = 0; i < sizeof(NodeStoredConfig); ++i) {
    checksum = ((checksum << 5) + checksum) ^ bytes[i];
  }

  return checksum;
}

static void copyString(char* dest, size_t destSize, const char* src) {
  if (destSize == 0) {
    return;
  }

  if (src == NULL) {
    dest[0] = '\0';
    return;
  }

  snprintf(dest, destSize, "%s", src);
}

void setNodeConfigDefaults(NodeStoredConfig* config) {
  memset(config, 0, sizeof(NodeStoredConfig));
  config->version = NODE_CONFIG_VERSION;
  config->provisioned = false;
  config->assigned = true;
  copyString(config->mqtt_broker, sizeof(config->mqtt_broker), MQTT_BROKER);
  config->mqtt_port = (uint16_t) MQTT_PORT;
  copyString(config->mqtt_username, sizeof(config->mqtt_username), MQTT_USERNAME);
  copyString(config->mqtt_password, sizeof(config->mqtt_password), MQTT_PASSWORD);
  copyString(config->node_id, sizeof(config->node_id), NODE_ID);
  copyString(config->zone_id, sizeof(config->zone_id), ZONE_ID);
  copyString(config->mqtt_client_id, sizeof(config->mqtt_client_id), MQTT_CLIENT_ID);
  config->zone_active = true;
  config->allowed_hours_enabled = false;
  config->allowed_start_hour = 0;
  config->allowed_end_hour = 0;
  config->dry_threshold = 0.0f;
  config->max_pulse_runtime_sec = 0;
  config->daily_max_runtime_sec = 0;
  config->time_to_harvest_days = 0;
}

bool loadNodeConfig(NodeStoredConfig* config) {
  setNodeConfigDefaults(config);
  StoredNodeConfigRecord record = nodeConfigStorage.read();

  if (record.config.version != NODE_CONFIG_VERSION) {
    return false;
  }

  if (record.checksum != checksumConfig(record.config)) {
    return false;
  }

  *config = record.config;
  return record.config.provisioned;
}

bool saveNodeConfig(const NodeStoredConfig& config) {
  StoredNodeConfigRecord record;
  record.config = config;
  record.config.version = NODE_CONFIG_VERSION;
  record.checksum = checksumConfig(record.config);
  nodeConfigStorage.write(record);
  return true;
}

bool clearNodeConfig() {
  StoredNodeConfigRecord record;
  memset(&record, 0, sizeof(record));
  nodeConfigStorage.write(record);
  return true;
}
