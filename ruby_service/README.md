# Victory Garden Rails Control Plane

Rails is the control plane + UI + system of record.

Responsibilities:
- Own configuration (crop profiles, zones, schedules, safety limits)
- Orchestrate decisions (not real-time control)
- Record history (readings, commands, actuator status, faults)
- Present info to humans (UI)

## Setup

From `ruby_service/`:

- Install gems:
  - `bundle install`
- Create DB:
  - `bin/rails db:create db:migrate`

## Key Models

- `CropProfile`: per-crop thresholds and runtime
- `Zone`: mapping of zone → crop + sensor node
- `SensorReading`: incoming sensor data
- `WateringEvent`: decisions/commands
- `ActuatorStatus`: status updates from devices
- `Fault`: faults/alerts

## Services

- `DecisionService`: decides when to water
- `WateringPolicy`: allowed hours checks
- `SensorIngestor`: validates + stores readings + triggers decision
- `CommandPublishJob`: publishes commands to MQTT
- `ConfigPublishJob`: publishes config to MQTT

## Jobs

- `SensorIngestJob`: background ingest + decision
- `CommandPublishJob`: publish watering command
- `ConfigPublishJob`: publish config to devices

## MQTT

Set environment variables:

- `MQTT_HOST` (default: `localhost`)
- `MQTT_PORT` (default: `1883`)
- `MQTT_COMMAND_TOPIC` (default: `watering/commands`)
- `MQTT_CONFIG_TOPIC` (default: `watering/config`)
- `MQTT_READINGS_TOPIC` (default: `watering/readings`)
- `MQTT_ACTUATORS_TOPIC` (default: `watering/actuators`)

## Ingestion Endpoint

POST `/ingest/sensor_readings`

Expected JSON payload:

```
{
  "sensor_reading": {
    "node_id": "sensor-gh1-zone1",
    "zone_id": "zone1",
    "timestamp": "2026-02-06T12:00:00Z",
    "moisture_raw": 1820,
    "moisture_percent": 31.4,
    "battery_voltage": 3.78,
    "rssi": -67
  }
}
```

Response: `202 Accepted` with `{ "status": "queued" }`

POST `/ingest/actuator_statuses`

Expected JSON payload:

```
{
  "actuator_status": {
    "zone_id": "zone1",
    "state": "COMPLETED",
    "timestamp": "2026-02-06T12:01:00Z",
    "idempotency_key": "zone1-20260206T120000Z-1",
    "actual_runtime_seconds": 45,
    "flow_ml": 820,
    "fault_code": null,
    "fault_detail": null
  }
}
```

Response: `202 Accepted` with `{ "status": "queued" }`

## MQTT Consumer

Standalone consumer process:

```
bin/mqtt_consumer
```

This subscribes to `MQTT_READINGS_TOPIC` and `MQTT_ACTUATORS_TOPIC` and enqueues
`SensorIngestJob` or `ActuatorStatusIngestJob` based on topic.

## Config Publish Trigger

POST `/admin/publish_config`

Response: `202 Accepted` with `{ "status": "queued" }`

## Notes

Rails does not do real-time control or hardware safety. Actuators must enforce safety limits.
