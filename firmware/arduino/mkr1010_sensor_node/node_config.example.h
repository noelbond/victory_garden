#ifndef NODE_CONFIG_H
#define NODE_CONFIG_H

// Copy this file to node_config.h and fill in local values.

// Wi-Fi
const char WIFI_SSID[] = "your-wifi-ssid";
const char WIFI_PASSWORD[] = "your-wifi-password";

// MQTT
const char MQTT_BROKER[] = "192.168.1.100";
const int MQTT_PORT = 1883;
const char MQTT_USERNAME[] = "";
const char MQTT_PASSWORD[] = "";

// Node identity
const char ZONE_ID[] = "zone1";
const char NODE_ID[] = "mkr1010-zone1";
const char MQTT_CLIENT_ID[] = "mkr1010-zone1";

// Provisioning
const char PROVISIONING_AP_SSID[] = "VictoryGardenSetup";
const char PROVISIONING_AP_PASSWORD[] = "gardensetup";
const unsigned long PROVISIONING_TRIGGER_WINDOW_MS = 5000UL;

// Sensor calibration
const int DRY_READING = 322;
const int WET_READING = 510;

// Timing
const unsigned long PUBLISH_INTERVAL_MS = 10800000UL;
const unsigned long WIFI_CONNECT_TIMEOUT_MS = 20000UL;
const unsigned long MQTT_CONNECT_TIMEOUT_MS = 15000UL;
const unsigned long COMMAND_LISTEN_WINDOW_MS = 420000UL;
const int MAX_CONSECUTIVE_FAILURES_BEFORE_RESET = 5;

// Optional battery monitoring
const bool ENABLE_BATTERY_MONITOR = true;
const int BATTERY_PIN = A1;
const float ADC_REFERENCE_VOLTAGE = 3.30f;
const int ADC_MAX = 4095;
const float R1_OHMS = 100000.0f;
const float R2_OHMS = 100000.0f;

// Device health thresholds
const long MIN_HEALTHY_WIFI_RSSI = -80;
const float MIN_HEALTHY_BATTERY_VOLTAGE = 3.40f;

#endif
