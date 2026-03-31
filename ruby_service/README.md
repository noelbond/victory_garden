# Victory Garden Rails Control Plane

Rails is the UI, configuration authority, persistence layer, and manual-operations surface.

## Responsibilities

- manage crop profiles and zones
- register provisioned nodes discovered from MQTT state payloads
- allow claiming many nodes to a zone through the UI
- consume node state, including optional telemetry fields when present
- record watering events, actuator status, and faults
- publish manual actuator commands plus node configuration
- publish retained system crop/zone config for the Python controller
- ingest Python controller events so automatic watering is persisted in the database
- schedule delayed reread requests 5 minutes after completed watering

## Shared Contract

Rails validates incoming node state against the shared contract fixtures in:

- [`../contracts/README.md`](/Users/noel/coding/python/victory_garden/contracts/README.md)
- [`../contracts/examples/node-state-v1.json`](/Users/noel/coding/python/victory_garden/contracts/examples/node-state-v1.json)

The Rails MQTT ingest path normalizes the canonical `node-state/v1` payload and still accepts the legacy `rssi` alias for compatibility.

## Setup

From [`ruby_service/`](/Users/noel/coding/python/victory_garden/ruby_service):

- `./bin/dev-bundle install`
- `./bin/dev-rails db:prepare`

Use the local wrappers for day-to-day work:

- `./bin/dev-rails s`
- `./bin/dev-rails test`
- `./bin/dev-smoke`
- `./bin/dev-rails runner 'puts RUBY_VERSION'`

Recommended local verification after setup:

- `./bin/dev-smoke`

## Main Models

- `CropProfile`
- `Node`
- `Zone`
- `SensorReading`
- `WateringEvent`
- `ActuatorStatus`
- `Fault`
- `ConnectionSetting`

## MQTT Defaults

- `MQTT_HOST`: `localhost`
- `MQTT_PORT`: `1883`
- `MQTT_USERNAME`: optional in local development, required on the deployed Pi
- `MQTT_PASSWORD`: optional in local development, required on the deployed Pi
- `MQTT_READINGS_TOPIC`: `greenhouse/zones/+/state`
- `MQTT_ACTUATORS_TOPIC`: `greenhouse/zones/+/actuator/status`
- node config topic: `greenhouse/nodes/{node_id}/config`
- node config ack topic: `greenhouse/nodes/{node_id}/config_ack`
- `MQTT_COMMAND_TOPIC`: `greenhouse/zones/{zone_id}/actuator/command`
- `MQTT_CONFIG_TOPIC`: `greenhouse/system/config/current`

## Source Of Truth

- PostgreSQL is authoritative for crop profiles, zones, node claims, watering history, faults, and node config sync status.
- MQTT retained node state is the live transport layer for sleeping devices and the Python controller's working input.
- `nodes.zone_id` is authoritative for routing. `reported_zone_id` from node payloads is stored for visibility only.
- The actuator service is external to this Rails app. Rails publishes manual zone-scoped actuator commands and consumes zone-scoped actuator status messages.

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

Consumed topic: `greenhouse/zones/{zone_id}/actuator/status`

Node config ack:

```json
{
  "schema_version": "node-config-ack/v1",
  "node_id": "mkr1010-zone1",
  "config_version": "2026-02-06T12:00:00Z",
  "status": "applied",
  "timestamp": "2026-02-06T12:00:03Z",
  "zone_id": "zone1",
  "applied_config": {
    "assigned": true
  },
  "error": null
}
```

## Reread Flow

When an actuator status of `COMPLETED` arrives:

1. Rails updates the watering event
2. Rails checks whether the zone already hit `daily_max_runtime_sec`
3. If not, Rails schedules a `RequestReadingJob` for 5 minutes later
4. That job publishes a retained `request_reading` command to `greenhouse/zones/{zone_id}/command`

## Command / Retry Notes

- Watering commands are published to `greenhouse/zones/{zone_id}/actuator/command`.
- `WateringEvent.idempotency_key` is the correlation key expected back from the actuator status payload.
- MQTT publish jobs use bounded retries, not infinite retry loops.
- Empty retained clears are ignored on the MQTT consumer side.

## Config Publish Payload

Published crop config includes:

- `crop_id`
- `crop_name`
- `dry_threshold`
- `max_pulse_runtime_sec`
- `daily_max_runtime_sec`
- `climate_preference`
- `time_to_harvest_days`

Claiming or unclaiming a node also publishes a node-specific config payload to `greenhouse/nodes/{node_id}/config`. Rails tracks the desired config, the last acked config, and the config sync status on each node record.

## MQTT Consumer

Run:

```bash
bin/mqtt_consumer
```

It subscribes to node state and actuator-status topics and enqueues the matching ingest jobs.

When broker auth is enabled, Rails uses `mqtt_username` and `mqtt_password` from `ConnectionSetting`, falling back to `MQTT_USERNAME` and `MQTT_PASSWORD` from the environment.

Empty retained clears are ignored cleanly.

If a node publishes state before a matching zone exists, Rails still registers the node by `node_id` and exposes it on the Nodes UI for claiming.

Once a node is claimed, Rails routes future readings by the claimed `node_id` mapping first. The node's reported `zone_id` is still stored for visibility, but it no longer overrides the claim.

Unclaimed nodes are registered and updated, but they do not persist readings.
Automatic watering decisions are made by the Python controller, not by Rails.

Operator pages:

- onboarding: `/onboarding`
- health dashboard: `/health`

## Retention

`sensor_readings`, `watering_events`, `actuator_statuses`, and `faults` are historical tables. The app does not yet prune them automatically, so long-running Pi installs should define an archival or retention policy.
