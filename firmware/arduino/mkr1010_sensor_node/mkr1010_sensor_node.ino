/*
Victory Garden MKR WiFi 1010 Sensor Node

Payload schema versions:

- node-state/v1
  Required fields on greenhouse/zones/{zone_id}/nodes/{node_id}/state:
  schema_version, timestamp, zone_id, node_id, moisture_raw, moisture_percent
  Optional nullable fields on the same payload:
  soil_temp_c, battery_voltage, battery_percent, wifi_rssi, uptime_seconds,
  wake_count, ip, health, last_error, publish_reason

- node-command/v1
  Commands consumed from greenhouse/zones/{zone_id}/command:
  {"schema_version":"node-command/v1","command":"request_reading","command_id":"..."}

- node-command-ack/v1
  Command acknowledgements published to greenhouse/zones/{zone_id}/command_ack

- node-config/v1
  Config consumed from greenhouse/nodes/{node_id}/config

- node-config-ack/v1
  Config acknowledgements published to greenhouse/nodes/{node_id}/config_ack

This node uses greenhouse/* as the canonical MQTT transport, generates topics
from ZONE_ID, and publishes a single state payload with nullable optional fields.
*/

#include <SPI.h>
#include <time.h>
#include <WiFiNINA.h>
#include <PubSubClient.h>
#include <ArduinoLowPower.h>
#include "Adafruit_seesaw.h"
#include "node_config.h"
#include "node_storage.h"
#include "provisioning.h"

WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);
Adafruit_seesaw ss;
NodeStoredConfig currentConfig;

unsigned long wakeCount = 0;
int consecutiveFailureCount = 0;
char lastError[96] = "none";
bool pendingRequestReading = false;
char pendingCommandId[64] = "";
bool pendingConfigUpdate = false;
char pendingConfigPayload[768] = "";
char pendingConfigVersion[64] = "";

char topicState[96];
char topicStatus[96];
char topicMoisture[96];
char topicTemp[96];
char topicRaw[96];
char topicBattery[96];
char topicBatteryPercent[96];
char topicWifiRssi[96];
char topicUptime[96];
char topicWakeCount[96];
char topicIp[96];
char topicLastError[96];
char topicHealth[96];
char topicPublishStatus[96];
char topicCommand[96];
char topicCommandAck[96];
char topicNodeConfig[96];
char topicNodeConfigAck[96];

void buildTopic(char* buffer, size_t size, const char* suffix) {
  snprintf(buffer, size, "greenhouse/zones/%s/%s", currentConfig.zone_id, suffix);
}

void buildNodeTopic(char* buffer, size_t size, const char* suffix) {
  snprintf(buffer, size, "greenhouse/nodes/%s/%s", currentConfig.node_id, suffix);
}

void setupTopics() {
  snprintf(topicState, sizeof(topicState), "greenhouse/zones/%s/nodes/%s/state", currentConfig.zone_id, currentConfig.node_id);
  buildTopic(topicStatus, sizeof(topicStatus), "status");
  buildTopic(topicMoisture, sizeof(topicMoisture), "moisture_percent");
  buildTopic(topicTemp, sizeof(topicTemp), "soil_temp_c");
  buildTopic(topicRaw, sizeof(topicRaw), "moisture_raw");
  buildTopic(topicBattery, sizeof(topicBattery), "battery_voltage");
  buildTopic(topicBatteryPercent, sizeof(topicBatteryPercent), "battery_percent");
  buildTopic(topicWifiRssi, sizeof(topicWifiRssi), "wifi_rssi");
  buildTopic(topicUptime, sizeof(topicUptime), "uptime_seconds");
  buildTopic(topicWakeCount, sizeof(topicWakeCount), "wake_count");
  buildTopic(topicIp, sizeof(topicIp), "ip");
  buildTopic(topicLastError, sizeof(topicLastError), "last_error");
  buildTopic(topicHealth, sizeof(topicHealth), "health");
  buildTopic(topicPublishStatus, sizeof(topicPublishStatus), "publish_status");
  buildTopic(topicCommand, sizeof(topicCommand), "command");
  buildTopic(topicCommandAck, sizeof(topicCommandAck), "command_ack");
  buildNodeTopic(topicNodeConfig, sizeof(topicNodeConfig), "config");
  buildNodeTopic(topicNodeConfigAck, sizeof(topicNodeConfigAck), "config_ack");
}

const char* mqttClientId() {
  return currentConfig.mqtt_client_id[0] != '\0' ? currentConfig.mqtt_client_id : MQTT_CLIENT_ID;
}

void configureDefaultsForProvisionedMode() {
  setNodeConfigDefaults(&currentConfig);
}

bool shouldBootstrapFromDefaults(const NodeStoredConfig& config) {
  if (strcmp(config.wifi_ssid, "") == 0 || strcmp(config.wifi_password, "") == 0) {
    return false;
  }

  if (strcmp(config.wifi_ssid, "your-wifi-ssid") == 0 ||
      strcmp(config.wifi_password, "your-wifi-password") == 0) {
    return false;
  }

  if (strcmp(config.wifi_ssid, "compile-only-ssid") == 0 ||
      strcmp(config.wifi_password, "compile-only-password") == 0) {
    return false;
  }

  if (strcmp(config.mqtt_broker, "") == 0 ||
      strcmp(config.node_id, "") == 0 ||
      strcmp(config.zone_id, "") == 0) {
    return false;
  }

  return true;
}

void setLastError(const char* msg) {
  snprintf(lastError, sizeof(lastError), "%s", msg);
  Serial.print("ERROR: ");
  Serial.println(lastError);
}

void clearLastError() {
  snprintf(lastError, sizeof(lastError), "%s", "none");
}

void softwareReset() {
  Serial.println("Resetting MCU...");
  delay(250);
  NVIC_SystemReset();
}

void isoTimestampNow(char* buffer, size_t size) {
  unsigned long epoch = WiFi.getTime();
  if (epoch > 946684800UL) {
    time_t rawTime = (time_t) epoch;
    struct tm* utc = gmtime(&rawTime);
    if (utc != NULL) {
      strftime(buffer, size, "%Y-%m-%dT%H:%M:%SZ", utc);
      return;
    }
  }

  unsigned long seconds = millis() / 1000UL;
  snprintf(buffer, size, "1970-01-01T00:%02lu:%02luZ", (seconds / 60UL) % 60UL, seconds % 60UL);
}

int readMoisturePercent(uint16_t moistureRaw) {
  int percent = map((int) moistureRaw, DRY_READING, WET_READING, 0, 100);
  return constrain(percent, 0, 100);
}

float readBatteryVoltage() {
  if (!ENABLE_BATTERY_MONITOR) {
    return -1.0f;
  }

  analogReadResolution(12);
  int raw = analogRead(BATTERY_PIN);

  float pinVoltage = (raw * ADC_REFERENCE_VOLTAGE) / (float) ADC_MAX;
  return pinVoltage * ((R1_OHMS + R2_OHMS) / R2_OHMS);
}

// Piecewise-linear approximation of a typical Li-ion discharge curve.
// Breakpoints: 4.20V=100%, 4.00V=80%, 3.80V=50%, 3.60V=20%, 3.40V=5%, 3.20V=0%
int batteryPercentFromVoltage(float voltage) {
  if (voltage < 0.0f)   return -1;
  if (voltage >= 4.20f) return 100;
  if (voltage >= 4.00f) return (int)(80.0f + (voltage - 4.00f) / 0.20f * 20.0f);
  if (voltage >= 3.80f) return (int)(50.0f + (voltage - 3.80f) / 0.20f * 30.0f);
  if (voltage >= 3.60f) return (int)(20.0f + (voltage - 3.60f) / 0.20f * 30.0f);
  if (voltage >= 3.40f) return (int)( 5.0f + (voltage - 3.40f) / 0.20f * 15.0f);
  if (voltage >= 3.20f) return (int)(        (voltage - 3.20f) / 0.20f *  5.0f);
  return 0;
}

unsigned long uptimeSeconds() {
  return millis() / 1000UL;
}

void ipToString(IPAddress ip, char* buffer, size_t size) {
  snprintf(buffer, size, "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);
}

bool publishRetained(const char* topic, const char* payload) {
  bool ok = mqttClient.publish(topic, payload, true);
  if (!ok) {
    setLastError("mqtt publish failed");
  }
  return ok;
}

bool publishInt(const char* topic, long value) {
  char buffer[24];
  snprintf(buffer, sizeof(buffer), "%ld", value);
  return publishRetained(topic, buffer);
}

bool publishFloat(const char* topic, float value, int decimals = 2) {
  char buffer[24];
  snprintf(buffer, sizeof(buffer), "%.*f", decimals, value);
  return publishRetained(topic, buffer);
}

bool computeDeviceHealthy(uint16_t moistureRaw, float batteryVoltage, long wifiRssi) {
  bool deviceHealthy = true;

  if (WiFi.status() != WL_CONNECTED) {
    deviceHealthy = false;
  }

  if (strcmp(lastError, "none") != 0) {
    deviceHealthy = false;
  }

  if (wifiRssi != 0 && wifiRssi < MIN_HEALTHY_WIFI_RSSI) {
    deviceHealthy = false;
  }

  if (ENABLE_BATTERY_MONITOR && batteryVoltage >= 0.0f && batteryVoltage < MIN_HEALTHY_BATTERY_VOLTAGE) {
    deviceHealthy = false;
  }

  if (moistureRaw == 0 || moistureRaw > 2000) {
    deviceHealthy = false;
  }

  return deviceHealthy;
}

void clearRetainedCommand() {
  mqttClient.publish(topicCommand, "", true);
}

void publishCommandAck(const char* command, const char* commandId, const char* status) {
  char payload[256];

  snprintf(
    payload,
    sizeof(payload),
    "{\"schema_version\":\"node-command-ack/v1\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"command\":\"%s\",\"command_id\":\"%s\",\"status\":\"%s\"}",
    currentConfig.zone_id,
    currentConfig.node_id,
    command,
    commandId,
    status
  );

  publishRetained(topicCommandAck, payload);
}

void publishNodeConfigAck(const char* status, const char* errorMessage) {
  char payload[640];
  char timestamp[32];

  isoTimestampNow(timestamp, sizeof(timestamp));

  if (currentConfig.assigned) {
    snprintf(
      payload,
      sizeof(payload),
      "{\"schema_version\":\"node-config-ack/v1\",\"node_id\":\"%s\",\"config_version\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"applied_config\":{\"assigned\":true,\"zone_id\":\"%s\",\"crop_id\":\"%s\"},\"error\":%s}",
      currentConfig.node_id,
      pendingConfigVersion,
      status,
      timestamp,
      currentConfig.zone_id,
      currentConfig.zone_id,
      currentConfig.crop_id,
      errorMessage != NULL ? errorMessage : "null"
    );
  } else {
    snprintf(
      payload,
      sizeof(payload),
      "{\"schema_version\":\"node-config-ack/v1\",\"node_id\":\"%s\",\"config_version\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"applied_config\":{\"assigned\":false},\"error\":%s}",
      currentConfig.node_id,
      pendingConfigVersion,
      status,
      timestamp,
      currentConfig.zone_id,
      errorMessage != NULL ? errorMessage : "null"
    );
  }
  publishRetained(topicNodeConfigAck, payload);
}

bool extractJsonString(const char* payload, const char* key, char* out, size_t outSize) {
  char pattern[48];
  snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
  char* start = strstr(const_cast<char*>(payload), pattern);
  if (start == NULL) {
    return false;
  }

  start += strlen(pattern);
  char* end = strchr(start, '"');
  if (end == NULL) {
    return false;
  }

  size_t copyLen = (size_t) (end - start);
  if (copyLen >= outSize) {
    copyLen = outSize - 1;
  }
  memcpy(out, start, copyLen);
  out[copyLen] = '\0';
  return true;
}

bool extractJsonBool(const char* payload, const char* key, bool* out) {
  char pattern[40];
  snprintf(pattern, sizeof(pattern), "\"%s\":", key);
  char* start = strstr(const_cast<char*>(payload), pattern);
  if (start == NULL) {
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

bool extractJsonInt(const char* payload, const char* key, long* out) {
  char pattern[40];
  snprintf(pattern, sizeof(pattern), "\"%s\":", key);
  char* start = strstr(const_cast<char*>(payload), pattern);
  if (start == NULL) {
    return false;
  }

  start += strlen(pattern);
  *out = strtol(start, NULL, 10);
  return true;
}

bool extractJsonFloat(const char* payload, const char* key, float* out) {
  char pattern[40];
  snprintf(pattern, sizeof(pattern), "\"%s\":", key);
  char* start = strstr(const_cast<char*>(payload), pattern);
  if (start == NULL) {
    return false;
  }

  start += strlen(pattern);
  *out = strtof(start, NULL);
  return true;
}

void clearConfigDerivedFields(NodeStoredConfig* config) {
  config->assigned = false;
  snprintf(config->zone_id, sizeof(config->zone_id), "%s", "unassigned");
  config->config_version[0] = '\0';
  config->zone_active = false;
  config->allowed_hours_enabled = false;
  config->allowed_start_hour = 0;
  config->allowed_end_hour = 0;
  config->crop_id[0] = '\0';
  config->crop_name[0] = '\0';
  config->dry_threshold = 0.0f;
  config->max_pulse_runtime_sec = 0;
  config->daily_max_runtime_sec = 0;
  config->climate_preference[0] = '\0';
  config->time_to_harvest_days = 0;
}

bool applyPendingConfig() {
  if (!pendingConfigUpdate) {
    return false;
  }

  NodeStoredConfig updatedConfig = currentConfig;
  char configVersion[sizeof(updatedConfig.config_version)];
  bool assigned = false;
  char zoneId[sizeof(updatedConfig.zone_id)];
  char cropId[sizeof(updatedConfig.crop_id)];
  char cropName[sizeof(updatedConfig.crop_name)];
  char climatePreference[sizeof(updatedConfig.climate_preference)];
  float dryThreshold = 0.0f;
  long maxPulseRuntime = 0;
  long dailyMaxRuntime = 0;
  long harvestDays = 0;
  bool zoneActive = false;
  long startHour = 0;
  long endHour = 0;

  if (!extractJsonString(pendingConfigPayload, "config_version", configVersion, sizeof(configVersion))) {
    setLastError("config version missing");
    publishNodeConfigAck("error", "\"config version missing\"");
    pendingConfigUpdate = false;
    return false;
  }

  snprintf(pendingConfigVersion, sizeof(pendingConfigVersion), "%s", configVersion);

  if (!extractJsonBool(pendingConfigPayload, "assigned", &assigned)) {
    setLastError("assigned missing");
    publishNodeConfigAck("error", "\"assigned missing\"");
    pendingConfigUpdate = false;
    return false;
  }

  snprintf(updatedConfig.config_version, sizeof(updatedConfig.config_version), "%s", configVersion);

  if (!assigned) {
    clearConfigDerivedFields(&updatedConfig);
    snprintf(updatedConfig.config_version, sizeof(updatedConfig.config_version), "%s", configVersion);
  } else {
    if (!extractJsonString(pendingConfigPayload, "zone_id", zoneId, sizeof(zoneId)) ||
        !extractJsonString(pendingConfigPayload, "crop_id", cropId, sizeof(cropId))) {
      setLastError("zone or crop missing");
      publishNodeConfigAck("error", "\"zone or crop missing\"");
      pendingConfigUpdate = false;
      return false;
    }

    updatedConfig.assigned = true;
    snprintf(updatedConfig.zone_id, sizeof(updatedConfig.zone_id), "%s", zoneId);
    extractJsonString(pendingConfigPayload, "crop_name", cropName, sizeof(cropName));
    extractJsonString(pendingConfigPayload, "climate_preference", climatePreference, sizeof(climatePreference));
    extractJsonBool(pendingConfigPayload, "active", &zoneActive);
    extractJsonFloat(pendingConfigPayload, "dry_threshold", &dryThreshold);
    extractJsonInt(pendingConfigPayload, "max_pulse_runtime_sec", &maxPulseRuntime);
    extractJsonInt(pendingConfigPayload, "daily_max_runtime_sec", &dailyMaxRuntime);
    extractJsonInt(pendingConfigPayload, "time_to_harvest_days", &harvestDays);

    if (dryThreshold <= 0.0f || maxPulseRuntime <= 0 || dailyMaxRuntime <= 0) {
      setLastError("invalid numeric config values");
      publishNodeConfigAck("error", "\"invalid numeric config values\"");
      pendingConfigUpdate = false;
      return false;
    }

    updatedConfig.zone_active = zoneActive;
    snprintf(updatedConfig.crop_id, sizeof(updatedConfig.crop_id), "%s", cropId);
    snprintf(updatedConfig.crop_name, sizeof(updatedConfig.crop_name), "%s", cropName);
    snprintf(updatedConfig.climate_preference, sizeof(updatedConfig.climate_preference), "%s", climatePreference);
    updatedConfig.dry_threshold = dryThreshold;
    updatedConfig.max_pulse_runtime_sec = maxPulseRuntime > 0 ? (uint16_t) maxPulseRuntime : 0;
    updatedConfig.daily_max_runtime_sec = dailyMaxRuntime > 0 ? (uint16_t) dailyMaxRuntime : 0;
    updatedConfig.time_to_harvest_days = harvestDays > 0 ? (uint16_t) harvestDays : 0;

    if (extractJsonInt(pendingConfigPayload, "start_hour", &startHour) &&
        extractJsonInt(pendingConfigPayload, "end_hour", &endHour)) {
      updatedConfig.allowed_hours_enabled = true;
      updatedConfig.allowed_start_hour = (uint8_t) startHour;
      updatedConfig.allowed_end_hour = (uint8_t) endHour;
    } else {
      updatedConfig.allowed_hours_enabled = false;
      updatedConfig.allowed_start_hour = 0;
      updatedConfig.allowed_end_hour = 0;
    }
  }

  if (!saveNodeConfig(updatedConfig)) {
    setLastError("config save failed");
    publishNodeConfigAck("error", "\"config save failed\"");
    pendingConfigUpdate = false;
    return false;
  }

  currentConfig = updatedConfig;
  setupTopics();
  mqttClient.subscribe(topicCommand);
  mqttClient.subscribe(topicNodeConfig);
  clearLastError();
  publishNodeConfigAck("applied", NULL);
  pendingConfigUpdate = false;
  return true;
}

void mqttCallback(char* topic, byte* payload, unsigned int length) {
  char message[768];
  if (length >= sizeof(message)) {
    setLastError("mqtt payload too large");
    return;
  }

  memcpy(message, payload, length);
  message[length] = '\0';

  if (strcmp(topic, topicCommand) == 0) {
    if (strstr(message, "\"command\":\"request_reading\"") == NULL) {
      publishCommandAck("unknown", "", "ignored");
      return;
    }

    const char* commandIdKey = "\"command_id\":\"";
    char* commandIdStart = strstr(message, commandIdKey);
    if (commandIdStart != NULL) {
      commandIdStart += strlen(commandIdKey);
      char* commandIdEnd = strchr(commandIdStart, '"');
      if (commandIdEnd != NULL) {
        size_t lengthToCopy = (size_t) (commandIdEnd - commandIdStart);
        if (lengthToCopy >= sizeof(pendingCommandId)) {
          lengthToCopy = sizeof(pendingCommandId) - 1;
        }
        memcpy(pendingCommandId, commandIdStart, lengthToCopy);
        pendingCommandId[lengthToCopy] = '\0';
      }
    } else {
      snprintf(pendingCommandId, sizeof(pendingCommandId), "%s", "");
    }

    pendingRequestReading = true;
    return;
  }

  if (strcmp(topic, topicNodeConfig) == 0) {
    char nodeId[sizeof(currentConfig.node_id)];
    if (!extractJsonString(message, "node_id", nodeId, sizeof(nodeId)) ||
        strcmp(nodeId, currentConfig.node_id) != 0) {
      return;
    }

    snprintf(pendingConfigPayload, sizeof(pendingConfigPayload), "%s", message);
    pendingConfigUpdate = true;
  }
}

bool connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) {
    return true;
  }

  Serial.print("Connecting to WiFi");
  WiFi.disconnect();
  WiFi.begin(currentConfig.wifi_ssid, currentConfig.wifi_password);

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
    Serial.print(".");

    if (millis() - start > WIFI_CONNECT_TIMEOUT_MS) {
      Serial.println();
      setLastError("wifi connect timeout");
      return false;
    }
  }

  Serial.println();
  Serial.println("WiFi connected");
  clearLastError();
  return true;
}

bool connectMQTT() {
  mqttClient.setBufferSize(768);
  mqttClient.setServer(currentConfig.mqtt_broker, currentConfig.mqtt_port);
  mqttClient.setCallback(mqttCallback);

  unsigned long start = millis();
  while (!mqttClient.connected()) {
    Serial.print("Connecting to MQTT... ");

    bool connected = false;
    if (strlen(currentConfig.mqtt_username) > 0) {
      connected = mqttClient.connect(
        mqttClientId(),
        currentConfig.mqtt_username,
        currentConfig.mqtt_password,
        topicStatus,
        0,
        true,
        "offline"
      );
    } else {
      connected = mqttClient.connect(
        mqttClientId(),
        topicStatus,
        0,
        true,
        "offline"
      );
    }

    if (connected) {
      Serial.println("connected");
      mqttClient.subscribe(topicCommand);
      mqttClient.subscribe(topicNodeConfig);
      publishRetained(topicStatus, "online");
      clearLastError();
      return true;
    }

    Serial.print("failed rc=");
    Serial.println(mqttClient.state());
    delay(1000);

    if (millis() - start > MQTT_CONNECT_TIMEOUT_MS) {
      setLastError("mqtt connect timeout");
      return false;
    }
  }

  return true;
}

bool ensureConnections() {
  if (!connectWiFi()) {
    return false;
  }

  if (!connectMQTT()) {
    return false;
  }

  return true;
}

void disconnectForSleep() {
  if (mqttClient.connected()) {
    mqttClient.publish(topicStatus, "sleeping", true);
    delay(100);
    mqttClient.disconnect();
    delay(100);
  }

  WiFi.end();
  delay(100);
}

bool publishTelemetry(const char* publishReason) {
  float soilTempC = ss.getTemp();
  uint16_t moistureRaw = ss.touchRead(0);
  int moisturePercent = readMoisturePercent(moistureRaw);
  float batteryVoltage = readBatteryVoltage();
  int batteryPercent = batteryPercentFromVoltage(batteryVoltage);
  long wifiRssi = (WiFi.status() == WL_CONNECTED) ? WiFi.RSSI() : 0;
  unsigned long uptimeSec = uptimeSeconds();
  bool deviceHealthy = computeDeviceHealthy(moistureRaw, batteryVoltage, wifiRssi);

  char statePayload[512];
  char timestamp[32];
  char ipBuffer[20];

  isoTimestampNow(timestamp, sizeof(timestamp));
  ipToString(WiFi.localIP(), ipBuffer, sizeof(ipBuffer));

  bool publishOk = true;

  if (ENABLE_BATTERY_MONITOR && batteryVoltage >= 0.0f) {
    snprintf(
      statePayload,
      sizeof(statePayload),
      "{\"schema_version\":\"node-state/v1\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"moisture_raw\":%u,\"moisture_percent\":%d,\"soil_temp_c\":%.2f,\"battery_voltage\":%.2f,\"battery_percent\":%d,\"wifi_rssi\":%ld,\"uptime_seconds\":%lu,\"wake_count\":%lu,\"ip\":\"%s\",\"health\":\"%s\",\"last_error\":\"%s\",\"publish_reason\":\"%s\"}",
      timestamp,
      currentConfig.zone_id,
      currentConfig.node_id,
      moistureRaw,
      moisturePercent,
      soilTempC,
      batteryVoltage,
      batteryPercent,
      wifiRssi,
      uptimeSec,
      wakeCount,
      ipBuffer,
      deviceHealthy ? "ok" : "degraded",
      lastError,
      publishReason
    );
    publishOk &= publishFloat(topicBattery, batteryVoltage, 2);
    publishOk &= publishInt(topicBatteryPercent, batteryPercent);
  } else {
    snprintf(
      statePayload,
      sizeof(statePayload),
      "{\"schema_version\":\"node-state/v1\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"moisture_raw\":%u,\"moisture_percent\":%d,\"soil_temp_c\":%.2f,\"battery_voltage\":null,\"battery_percent\":null,\"wifi_rssi\":%ld,\"uptime_seconds\":%lu,\"wake_count\":%lu,\"ip\":\"%s\",\"health\":\"%s\",\"last_error\":\"%s\",\"publish_reason\":\"%s\"}",
      timestamp,
      currentConfig.zone_id,
      currentConfig.node_id,
      moistureRaw,
      moisturePercent,
      soilTempC,
      wifiRssi,
      uptimeSec,
      wakeCount,
      ipBuffer,
      deviceHealthy ? "ok" : "degraded",
      lastError,
      publishReason
    );
  }

  publishOk &= publishRetained(topicState, statePayload);
  publishOk &= publishInt(topicMoisture, moisturePercent);
  publishOk &= publishInt(topicRaw, moistureRaw);
  publishOk &= publishFloat(topicTemp, soilTempC, 2);
  publishOk &= publishInt(topicWifiRssi, wifiRssi);
  publishOk &= publishInt(topicUptime, uptimeSec);
  publishOk &= publishInt(topicWakeCount, wakeCount);
  publishOk &= publishRetained(topicIp, ipBuffer);
  publishOk &= publishRetained(topicLastError, lastError);
  publishOk &= publishRetained(topicHealth, deviceHealthy ? "ok" : "degraded");
  publishOk &= publishRetained(topicPublishStatus, publishOk ? "ok" : "failed");
  publishOk &= publishRetained(topicStatus, "online");

  Serial.println();
  Serial.println("Published telemetry:");
  Serial.print("  Reason: ");
  Serial.println(publishReason);
  Serial.print("  Moisture raw: ");
  Serial.println(moistureRaw);
  Serial.print("  Moisture %: ");
  Serial.println(moisturePercent);
  Serial.print("  Soil temp C: ");
  Serial.println(soilTempC, 2);
  Serial.print("  WiFi RSSI: ");
  Serial.println(wifiRssi);
  Serial.print("  Uptime sec: ");
  Serial.println(uptimeSec);
  Serial.print("  Wake count: ");
  Serial.println(wakeCount);

  if (ENABLE_BATTERY_MONITOR && batteryVoltage >= 0.0f) {
    Serial.print("  Battery V: ");
    Serial.println(batteryVoltage, 2);
    Serial.print("  Battery %: ");
    Serial.println(batteryPercent);
  } else {
    Serial.println("  Battery monitor: disabled");
  }

  Serial.print("  Device health: ");
  Serial.println(deviceHealthy ? "ok" : "degraded");
  Serial.print("  Publish status: ");
  Serial.println(publishOk ? "ok" : "failed");
  Serial.print("  Last error: ");
  Serial.println(lastError);
  Serial.print("  State JSON: ");
  Serial.println(statePayload);
  Serial.println("----------------------------");

  return publishOk;
}

bool runTelemetryPublish(const char* publishReason) {
  bool published = publishTelemetry(publishReason);
  if (published) {
    consecutiveFailureCount = 0;
    clearLastError();
    publishRetained(topicLastError, lastError);
    publishRetained(topicPublishStatus, "ok");
  } else {
    consecutiveFailureCount++;
    publishRetained(topicPublishStatus, "failed");

    if (consecutiveFailureCount >= MAX_CONSECUTIVE_FAILURES_BEFORE_RESET) {
      softwareReset();
    }
  }

  mqttClient.loop();
  delay(100);
  return published;
}

bool processPendingCommand() {
  if (pendingConfigUpdate) {
    Serial.println("Applying node config update");
    return applyPendingConfig();
  }

  if (!pendingRequestReading) {
    return false;
  }

  Serial.println("Handling request_reading command");
  publishCommandAck("request_reading", pendingCommandId, "received");
  runTelemetryPublish("request_reading");
  publishCommandAck("request_reading", pendingCommandId, "handled");
  clearRetainedCommand();

  pendingRequestReading = false;
  pendingCommandId[0] = '\0';
  return true;
}

bool listenForCommands(unsigned long windowMs) {
  unsigned long start = millis();
  bool handledAny = false;

  while (millis() - start < windowMs) {
    mqttClient.loop();
    if (processPendingCommand()) {
      handledAny = true;
    }
    delay(100);
  }

  return handledAny;
}

void beginCycle() {
  wakeCount++;
  pendingRequestReading = false;
  pendingCommandId[0] = '\0';

  bool ok = ensureConnections();
  if (!ok) {
    consecutiveFailureCount++;
    Serial.print("Connection failure count: ");
    Serial.println(consecutiveFailureCount);

    if (consecutiveFailureCount >= MAX_CONSECUTIVE_FAILURES_BEFORE_RESET) {
      softwareReset();
    }
    return;
  }
}

void runScheduledCycle() {
  beginCycle();
  if (!mqttClient.connected()) {
    return;
  }

  mqttClient.loop();
  delay(250);
  mqttClient.loop();
  bool handledImmediateCommand = processPendingCommand();

  if (!handledImmediateCommand) {
    runTelemetryPublish("scheduled");
  }
  listenForCommands(COMMAND_LISTEN_WINDOW_MS);
}

void setup() {
  Serial.begin(115200);
  delay(1500);

  Serial.println();
  Serial.println("MKR WiFi 1010 Victory Garden sensor node starting...");

  analogReadResolution(12);

  if (!ss.begin(0x36)) {
    setLastError("seesaw sensor not found");
    Serial.println("Seesaw sensor not found. Halting.");
    while (true) {
      delay(1000);
    }
  }

  Serial.println("Seesaw sensor found.");

  configureDefaultsForProvisionedMode();
  bool loadedProvisionedConfig = loadNodeConfig(&currentConfig);
  bool forceProvisioning = shouldForceProvisioning();

  if (forceProvisioning) {
    Serial.println("Provisioning reset requested over serial.");
    clearNodeConfig();
    configureDefaultsForProvisionedMode();
    loadedProvisionedConfig = false;
  }

  if (!loadedProvisionedConfig) {
    if (shouldBootstrapFromDefaults(currentConfig)) {
      Serial.println("No saved node configuration found. Bootstrapping from local defaults.");
      currentConfig.provisioned = true;
      currentConfig.assigned = true;

      if (saveNodeConfig(currentConfig)) {
        Serial.println("Bootstrapped configuration saved.");
        loadedProvisionedConfig = true;
      } else {
        setLastError("failed to save bootstrapped config");
      }
    }
  }

  if (!loadedProvisionedConfig) {
    Serial.println("No saved node configuration found. Entering provisioning mode.");
    if (runProvisioningPortal(&currentConfig)) {
      if (saveNodeConfig(currentConfig)) {
        Serial.println("Provisioned configuration saved. Rebooting.");
        delay(500);
        softwareReset();
      }
      setLastError("failed to save provisioned config");
    } else {
      setLastError("provisioning failed");
    }
    return;
  }

  setupTopics();
  runScheduledCycle();
}

unsigned long secondsUntilNextPublish() {
  unsigned long epoch = WiFi.getTime();
  if (epoch < 946684800UL) {
    Serial.println("NTP unavailable, using fallback sleep interval");
    return NTP_FALLBACK_SLEEP_SEC;
  }

  // Apply UTC offset to convert to local time
  long localEpoch = (long)epoch + (long)UTC_OFFSET_HOURS * 3600L;
  if (localEpoch < 0) localEpoch = 0;
  struct tm* t = gmtime((time_t*)&localEpoch);

  int nowSec = t->tm_hour * 3600 + t->tm_min * 60 + t->tm_sec;
  unsigned long minDiff = 86400UL;
  for (int i = 0; i < PUBLISH_SCHEDULE_COUNT; i++) {
    int diff = PUBLISH_SCHEDULE_LOCAL_HOURS[i] * 3600 - nowSec;
    if (diff <= 0) diff += 86400;
    if ((unsigned long)diff < minDiff) minDiff = (unsigned long)diff;
  }
  return minDiff;
}

void loop() {
  disconnectForSleep();
  unsigned long sleepSec = secondsUntilNextPublish();
  Serial.print("Deep sleeping for seconds: ");
  Serial.println(sleepSec);
  LowPower.deepSleep(sleepSec * 1000UL);
  Serial.println("Woke up for scheduled publish");
  runScheduledCycle();
}
