# MKR WiFi 1010 Sensor Node

Arduino firmware for a Victory Garden moisture sensor node.

## Features

- Generates MQTT topics from `ZONE_ID`
- Uses `greenhouse/*` topics consistently
- Publishes one `state` payload with required fields and nullable optional telemetry fields
- Uses `moisture_raw` and `wifi_rssi` field names
- Sleeps with `ArduinoLowPower` between scheduled readings
- Supports retained `request_reading` commands for post-watering rereads
- Stays awake only in the immediate post-publish watch window so delayed reread requests can be handled

## Files

- `mkr1010_sensor_node.ino`: main firmware sketch
- `node_config.example.h`: copy to `node_config.h` and fill in local secrets/calibration

## Command Contract

Command topic:

`greenhouse/zones/{zone_id}/command`

Example retained payload:

```json
{
  "schema_version": "node-command/v1",
  "command": "request_reading",
  "command_id": "zone1-20260210T120000Z-reread"
}
```

Ack topic:

`greenhouse/zones/{zone_id}/command_ack`

Example ack payload:

```json
{
  "schema_version": "node-command-ack/v1",
  "zone_id": "zone1",
  "node_id": "mkr1010-zone1",
  "command": "request_reading",
  "command_id": "zone1-20260210T120000Z-reread",
  "status": "handled"
}
```

After handling a retained command, the node clears the command topic by publishing an empty retained payload. That prevents the same reread request from replaying after every reconnect.

## Required State Payload

Topic:

`greenhouse/zones/{zone_id}/state`

Payload:

```json
{
  "schema_version": "node-state/v1",
  "timestamp": "2026-02-10T12:00:00Z",
  "zone_id": "zone1",
  "node_id": "mkr1010-zone1",
  "moisture_raw": 510,
  "moisture_percent": 27,
  "soil_temp_c": 24.8,
  "battery_voltage": 4.02,
  "battery_percent": 89,
  "wifi_rssi": -53,
  "uptime_seconds": 607,
  "wake_count": 1042,
  "ip": "192.168.4.21",
  "health": "ok",
  "last_error": "none",
  "publish_reason": "scheduled"
}
```

## Libraries

- `WiFiNINA`
- `PubSubClient`
- `Adafruit seesaw`
- `ArduinoLowPower`

## Setup

1. Copy `node_config.example.h` to `node_config.h`
2. Fill in local Wi-Fi, MQTT, and calibration values
3. Open `mkr1010_sensor_node.ino` in the Arduino IDE
4. Select the MKR WiFi 1010 board and upload

## Note On Rereads

The node deep-sleeps between scheduled publishes. After each scheduled reading, it stays connected only for the immediate post-publish watch window so a delayed `request_reading` command can be handled if watering just occurred.
