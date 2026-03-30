# MKR WiFi 1010 Sensor Node

Arduino firmware for a Victory Garden moisture sensor node.

## Features

- Generates MQTT topics from `ZONE_ID`
- Uses `greenhouse/*` topics consistently
- Publishes one `state` payload with required fields and nullable optional telemetry fields
- Uses `moisture_raw` and `wifi_rssi` field names
- Stores provisioned Wi-Fi and MQTT settings in flash
- Persists applied zone/crop config pushed from Rails
- Starts a temporary setup AP when the node is unprovisioned
- Sleeps with `ArduinoLowPower` between scheduled readings
- Supports retained `request_reading` commands for post-watering rereads
- Subscribes to retained node config and publishes config acknowledgements
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

## Runtime Config Sync

Config topic:

`greenhouse/nodes/{node_id}/config`

Example retained payload:

```json
{
  "schema_version": "node-config/v1",
  "config_version": "2026-02-10T12:00:00Z",
  "issued_at": "2026-02-10T12:00:00Z",
  "node_id": "mkr1010-zone1",
  "assigned": true,
  "zone": {
    "zone_id": "zone1",
    "active": true,
    "allowed_hours": {
      "start_hour": 6,
      "end_hour": 20
    }
  },
  "crop": {
    "crop_id": "tomato",
    "crop_name": "Tomato",
    "dry_threshold": 30.0,
    "max_pulse_runtime_sec": 45,
    "daily_max_runtime_sec": 300,
    "climate_preference": "Warm, sunny",
    "time_to_harvest_days": 75
  }
}
```

Config ack topic:

`greenhouse/nodes/{node_id}/config_ack`

Example ack payload:

```json
{
  "schema_version": "node-config-ack/v1",
  "node_id": "mkr1010-zone1",
  "config_version": "2026-02-10T12:00:00Z",
  "status": "applied",
  "timestamp": "2026-02-10T12:00:02Z",
  "zone_id": "zone1",
  "applied_config": {
    "assigned": true,
    "zone_id": "zone1",
    "crop_id": "tomato"
  },
  "error": null
}
```

The node subscribes to its retained config topic each time it connects to MQTT, applies the latest config, saves it to flash, and acknowledges the applied version.

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

This example is mirrored in the shared contract fixtures under [`contracts/examples/node-state-v1.json`](/Users/noel/coding/python/victory_garden/contracts/examples/node-state-v1.json).

## Libraries

- `WiFiNINA`
- `PubSubClient`
- `Adafruit seesaw`
- `ArduinoLowPower`
- `FlashStorage`

## Setup

1. Copy `node_config.example.h` to `node_config.h`
2. Fill in local defaults, calibration values, and provisioning AP settings
3. Open `mkr1010_sensor_node.ino` in the Arduino IDE
4. Select the MKR WiFi 1010 board and upload

## Reset And Upload Sequence

Use these exact actions on an MKR WiFi 1010:

1. Close Serial Monitor before uploading.
2. Select board `Arduino MKR WiFi 1010`.
3. Select the current USB port for the board.
4. Click Upload.
5. If upload stalls, double-press the reset button to enter bootloader mode, then retry the upload.
6. For a normal reboot and serial logs, press reset once.

## Provisioning

If the node has no saved configuration, it boots into provisioning mode and starts a temporary Wi-Fi access point using `PROVISIONING_AP_SSID`.

Open the node IP shown on serial output in a browser, then enter:

- Wi-Fi SSID
- Wi-Fi password
- MQTT broker host
- MQTT port
- node ID
- zone ID

The node saves the configuration to flash and reboots into normal mode.

During boot, sending `p`, `P`, `r`, or `R` over serial within the provisioning trigger window clears saved config and forces reprovisioning.

Because the stored config format changed to include applied zone/crop config, flashing this firmware over an older build will invalidate the old saved config and require one reprovisioning pass.

## Note On Rereads

The node deep-sleeps between scheduled publishes. After each scheduled reading, it stays connected only for the immediate post-publish watch window so a delayed `request_reading` command can be handled if watering just occurred.

## Firmware Troubleshooting

- If upload fails with `No upload port found`, close Serial Monitor and retry.
- If the board still will not upload, double-press reset and retry while the bootloader is active.
- If the node prints `No saved node configuration found. Entering provisioning mode.`, it is waiting for Wi-Fi/MQTT setup through the temporary AP.
- If serial shows `Publish status: ok`, the node has joined Wi-Fi and published to MQTT successfully.
- If `Device health` is `degraded`, inspect battery voltage and RSSI in the state payload.
