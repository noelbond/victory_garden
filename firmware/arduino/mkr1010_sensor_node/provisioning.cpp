#include "provisioning.h"

#include <WiFiNINA.h>

#include "node_config.h"
#include "node_storage.h"

namespace {
WiFiServer provisioningServer(80);
bool provisioningServerStarted = false;

void copyString(char* dest, size_t destSize, const String& src) {
  snprintf(dest, destSize, "%s", src.c_str());
}

String urlDecode(const String& value) {
  String decoded;
  decoded.reserve(value.length());

  for (size_t i = 0; i < value.length(); ++i) {
    char c = value[i];
    if (c == '+') {
      decoded += ' ';
      continue;
    }

    if (c == '%' && i + 2 < value.length()) {
      char high = value[i + 1];
      char low = value[i + 2];
      char hex[3] = {high, low, '\0'};
      decoded += (char) strtol(hex, NULL, 16);
      i += 2;
      continue;
    }

    decoded += c;
  }

  return decoded;
}

String paramValue(const String& query, const char* key) {
  String needle = String(key) + "=";
  int start = query.indexOf(needle);
  if (start < 0) {
    return "";
  }

  start += needle.length();
  int end = query.indexOf('&', start);
  if (end < 0) {
    end = query.length();
  }

  return urlDecode(query.substring(start, end));
}

void sendHtml(
  WiFiClient& client,
  const NodeStoredConfig& config,
  const char* statusMessage
) {
  client.println("HTTP/1.1 200 OK");
  client.println("Content-Type: text/html; charset=utf-8");
  client.println("Connection: close");
  client.println();
  client.println("<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
  client.println("<title>Victory Garden Setup</title></head><body>");
  client.println("<h1>Victory Garden Node Setup</h1>");
  if (statusMessage != NULL && statusMessage[0] != '\0') {
    client.print("<p><strong>");
    client.print(statusMessage);
    client.println("</strong></p>");
  }
  client.println("<form action=\"/save\" method=\"get\">");
  client.print("<label>WiFi SSID<br><input name=\"ssid\" value=\"");
  client.print(config.wifi_ssid);
  client.println("\"></label><br><br>");
  client.print("<label>WiFi Password<br><input name=\"password\" type=\"password\" value=\"");
  client.print(config.wifi_password);
  client.println("\"></label><br><br>");
  client.print("<label>MQTT Broker<br><input name=\"broker\" value=\"");
  client.print(config.mqtt_broker);
  client.println("\"></label><br><br>");
  client.print("<label>MQTT Port<br><input name=\"port\" type=\"number\" value=\"");
  client.print(config.mqtt_port);
  client.println("\"></label><br><br>");
  client.print("<label>Node ID<br><input name=\"node_id\" value=\"");
  client.print(config.node_id);
  client.println("\"></label><br><br>");
  client.print("<label>Zone ID<br><input name=\"zone_id\" value=\"");
  client.print(config.zone_id);
  client.println("\"></label><br><br>");
  client.println("<button type=\"submit\">Save and reboot</button>");
  client.println("</form></body></html>");
}

bool applyQueryToConfig(const String& query, NodeStoredConfig* config, char* errorMessage, size_t errorMessageSize) {
  String ssid = paramValue(query, "ssid");
  String password = paramValue(query, "password");
  String broker = paramValue(query, "broker");
  String port = paramValue(query, "port");
  String nodeId = paramValue(query, "node_id");
  String zoneId = paramValue(query, "zone_id");

  if (ssid.length() == 0 || broker.length() == 0 || nodeId.length() == 0 || zoneId.length() == 0) {
    snprintf(errorMessage, errorMessageSize, "%s", "SSID, broker, node ID, and zone ID are required.");
    return false;
  }

  long mqttPort = port.length() > 0 ? port.toInt() : MQTT_PORT;
  if (mqttPort <= 0 || mqttPort > 65535) {
    snprintf(errorMessage, errorMessageSize, "%s", "MQTT port must be between 1 and 65535.");
    return false;
  }

  copyString(config->wifi_ssid, sizeof(config->wifi_ssid), ssid);
  copyString(config->wifi_password, sizeof(config->wifi_password), password);
  copyString(config->mqtt_broker, sizeof(config->mqtt_broker), broker);
  config->mqtt_port = (uint16_t) mqttPort;
  copyString(config->node_id, sizeof(config->node_id), nodeId);
  copyString(config->zone_id, sizeof(config->zone_id), zoneId);
  copyString(config->mqtt_client_id, sizeof(config->mqtt_client_id), nodeId);
  config->provisioned = true;

  snprintf(errorMessage, errorMessageSize, "%s", "");
  return true;
}
}

void provisioningSetup() {
  Serial.println("Starting provisioning mode");
  WiFi.end();

  int status = WL_IDLE_STATUS;
  if (strlen(PROVISIONING_AP_PASSWORD) >= 8) {
    status = WiFi.beginAP(PROVISIONING_AP_SSID, PROVISIONING_AP_PASSWORD);
  } else {
    status = WiFi.beginAP(PROVISIONING_AP_SSID);
  }

  if (status != WL_AP_LISTENING && status != WL_CONNECTED) {
    Serial.println("Failed to start provisioning AP");
    return;
  }

  if (!provisioningServerStarted) {
    provisioningServer.begin();
    provisioningServerStarted = true;
  }

  Serial.print("Provisioning AP ready: ");
  Serial.println(PROVISIONING_AP_SSID);
  Serial.print("Open http://");
  Serial.println(WiFi.localIP());
}

bool shouldForceProvisioning() {
  const unsigned long deadline = millis() + PROVISIONING_TRIGGER_WINDOW_MS;

  while (millis() < deadline) {
    if (Serial.available() > 0) {
      char incoming = (char) Serial.read();
      if (incoming == 'p' || incoming == 'P' || incoming == 'r' || incoming == 'R') {
        return true;
      }
    }
    delay(50);
  }

  return false;
}

bool runProvisioningPortal(NodeStoredConfig* config) {
  provisioningSetup();
  char statusMessage[120] = "";

  while (true) {
    WiFiClient client = provisioningServer.available();
    if (!client) {
      delay(50);
      continue;
    }

    String requestLine = client.readStringUntil('\n');
    requestLine.trim();

    while (client.connected()) {
      String line = client.readStringUntil('\n');
      if (line == "\r" || line.length() == 0) {
        break;
      }
    }

    if (requestLine.startsWith("GET /save?")) {
      int queryStart = requestLine.indexOf('?');
      int queryEnd = requestLine.indexOf(' ', queryStart);
      String query = requestLine.substring(queryStart + 1, queryEnd);

      if (applyQueryToConfig(query, config, statusMessage, sizeof(statusMessage))) {
        sendHtml(client, *config, "Configuration saved. Rebooting...");
        client.stop();
        delay(1000);
        return true;
      }
    }

    sendHtml(client, *config, statusMessage);
    client.stop();
  }
}
