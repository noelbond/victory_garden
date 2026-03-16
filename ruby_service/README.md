# Victory Garden Rails Control Plane

Rails is the UI, configuration authority, and historical reporting layer.

## Responsibilities

- manage crop profiles and zones
- consume node state, including optional telemetry fields when present
- record watering events, actuator status, and faults
- publish irrigation commands and device configuration
- schedule delayed reread requests 5 minutes after completed watering

## Setup

From [`ruby_service/`](/Users/noel/coding/python/victory_garden/ruby_service):

- `bundle install`
- `bin/rails db:create db:migrate`

## Main Models

- `CropProfile`
- `Zone`
- `SensorReading`
- `WateringEvent`
- `ActuatorStatus`
- `Fault`
- `ConnectionSetting`

## MQTT Defaults

- `MQTT_HOST`: `localhost`
- `MQTT_PORT`: `1883`
- `MQTT_READINGS_TOPIC`: `greenhouse/zones/+/state`
- `MQTT_ACTUATORS_TOPIC`: `greenhouse/zones/+/actuator_status`
- `MQTT_COMMAND_TOPIC`: `greenhouse/irrigation/commands`
- `MQTT_CONFIG_TOPIC`: `greenhouse/config/current`

## Consumed Payloads

Node state:

```json
{
  "schema_version": "node-state/v1",
  "timestamp": "2026-02-06T12:00:00Z",
  "zone_id": "zone1",
  "node_id": "mkr1010-zone1",
  "moisture_raw": 1820,
  "moisture_percent": 31.4,
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

Actuator status:

```json
{
  "zone_id": "zone1",
  "state": "COMPLETED",
  "timestamp": "2026-02-06T12:01:00Z",
  "idempotency_key": "zone1-20260206T120000Z-1",
  "actual_runtime_seconds": 45,
  "flow_ml": 820,
  "fault_code": null,
  "fault_detail": null
}
```

## Reread Flow

When an actuator status of `COMPLETED` arrives:

1. Rails updates the watering event
2. Rails checks whether the zone already hit `daily_max_runtime_sec`
3. If not, Rails schedules a `RequestReadingJob` for 5 minutes later
4. That job publishes a retained `request_reading` command to `greenhouse/zones/{zone_id}/command`

## Config Publish Payload

Published crop config includes:

- `crop_id`
- `crop_name`
- `dry_threshold`
- `max_pulse_runtime_sec`
- `daily_max_runtime_sec`
- `climate_preference`
- `time_to_harvest_days`

## MQTT Consumer

Run:

```bash
bin/mqtt_consumer
```

It subscribes to node state and actuator-status topics and enqueues the matching ingest jobs.
