/*
Victory Garden MKR WiFi 1010 Sensor Node

Payload schema versions:

- node-state/v1
  Required fields on greenhouse/zones/{zone_id}/state:
  schema_version, timestamp, zone_id, node_id, moisture_raw, moisture_percent
  Optional nullable fields on the same payload:
  soil_temp_c, battery_voltage, battery_percent, wifi_rssi, uptime_seconds,
  wake_count, ip, health, last_error, publish_reason

- node-command/v1
  Commands consumed from greenhouse/zones/{zone_id}/command:
  {"schema_version":"node-command/v1","command":"request_reading","command_id":"..."}

- node-command-ack/v1
  Command acknowledgements published to greenhouse/zones/{zone_id}/command_ack

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

WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);
Adafruit_seesaw ss;

unsigned long wakeCount = 0;
int consecutiveFailureCount = 0;
char lastError[96] = "none";
bool pendingRequestReading = false;
char pendingCommandId[64] = "";

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

void buildTopic(char* buffer, size_t size, const char* suffix) {
  snprintf(buffer, size, "greenhouse/zones/%s/%s", ZONE_ID, suffix);
}

void setupTopics() {
  buildTopic(topicState, sizeof(topicState), "state");
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

int batteryPercentFromVoltage(float voltage) {
  if (voltage < 0.0f) return -1;
  if (voltage >= 4.20f) return 100;
  if (voltage <= 3.20f) return 0;

  int percent = (int) ((voltage - 3.20f) * 100.0f);
  return constrain(percent, 0, 100);
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
    ZONE_ID,
    NODE_ID,
    command,
    commandId,
    status
  );

  publishRetained(topicCommandAck, payload);
}

void mqttCallback(char* topic, byte* payload, unsigned int length) {
  char message[256];
  if (length >= sizeof(message)) {
    setLastError("command payload too large");
    return;
  }

  memcpy(message, payload, length);
  message[length] = '\0';

  if (strcmp(topic, topicCommand) != 0) {
    return;
  }

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
}

bool connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) {
    return true;
  }

  Serial.print("Connecting to WiFi");
  WiFi.disconnect();
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

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
  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  mqttClient.setCallback(mqttCallback);

  unsigned long start = millis();
  while (!mqttClient.connected()) {
    Serial.print("Connecting to MQTT... ");

    bool connected = false;
    if (strlen(MQTT_USERNAME) > 0) {
      connected = mqttClient.connect(
        MQTT_CLIENT_ID,
        MQTT_USERNAME,
        MQTT_PASSWORD,
        topicStatus,
        0,
        true,
        "offline"
      );
    } else {
      connected = mqttClient.connect(
        MQTT_CLIENT_ID,
        topicStatus,
        0,
        true,
        "offline"
      );
    }

    if (connected) {
      Serial.println("connected");
      mqttClient.subscribe(topicCommand);
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
      ZONE_ID,
      NODE_ID,
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
      ZONE_ID,
      NODE_ID,
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

  setupTopics();

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
  runScheduledCycle();
}

void loop() {
  disconnectForSleep();
  Serial.print("Deep sleeping for ms: ");
  Serial.println(PUBLISH_INTERVAL_MS);
  LowPower.deepSleep(PUBLISH_INTERVAL_MS);
  Serial.println("Woke up for scheduled publish");
  runScheduledCycle();
}
