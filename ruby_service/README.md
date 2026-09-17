# Victory Garden Rails Control Plane

Rails is the UI, configuration authority, persistence layer, and manual-operations surface.

## Responsibilities

- manage crop profiles, Zone grouping, and Node configuration
- provision a Zone/package with four backend-created Node identities before telemetry
- reconcile known Node telemetry without letting reported device metadata rewrite topology
- consume node state, including optional telemetry fields when present
- record watering events, actuator status, and faults
- publish manual actuator commands plus node configuration
- publish retained Node crop and Zone schedule config for the Python controller
- ingest Python controller events so automatic watering is persisted in the database
- schedule delayed reread requests 5 minutes after completed watering

## Shared Contract

Rails validates incoming node state against the shared contract fixtures in:

- [`../contracts/README.md`](../contracts/README.md)
- [`../contracts/examples/node-state-v1.json`](../contracts/examples/node-state-v1.json)

The Rails MQTT ingest path validates the canonical `node-state/v1` payload and still accepts the legacy `rssi` alias for compatibility.

## Setup

From `ruby_service/`:

- `./bin/dev-bundle install`
- `./bin/dev-rails db:prepare`

Use the local wrappers for day-to-day work:

- `./bin/dev-rails s`
- `./bin/dev-rails test`
- `./bin/dev-smoke`
- `./bin/dev-rails runner 'puts RUBY_VERSION'`

Recommended local verification after setup:

- `./bin/dev-smoke`

`dev-smoke` is the fastest local check for the Rails-side end-to-end flow surface:

- manual watering command creation
- actuator status ingest and reread scheduling
- node config publish and config ack ingest
- MQTT topic normalization and retained-clear handling

## Operator Surfaces

Primary operator pages:

- Setup Checklist: `/onboarding`
- Health: `/health`
- Reading History: `/reading_history`
- Watering Events: `/watering_events`
- Settings: `/settings`

Reading History is the cross-node operator inbox. It supports:

- `Readings` and `Trends` tabs
- zone and node filtering
- `Freshness`, `Health`, `Publish Reason`, moisture-range, and error filters
- CSV export for the current filtered result set
- per-column sort and selectable visible columns

Node detail pages also expose `View Node Readings`, which is the node-scoped version of the same filtering/export surface.

## Main Models

- `CropProfile`
- `Node`
- `Zone`
- `SensorReading`
- `WateringEvent`
- `ActuatorStatus`
- `Fault`
- `ConnectionSetting`

Crop profiles are user-managed from the Rails UI and assigned to individual
Nodes. A Zone may contain Nodes with different crops; crop-less Nodes are valid
during setup but cannot use crop-derived watering.

## MQTT Defaults

- `MQTT_HOST`: `localhost`
- `MQTT_PORT`: `1883`
- `MQTT_USERNAME`: optional in local development, required on the deployed Pi
- `MQTT_PASSWORD`: optional in local development, required on the deployed Pi
- `MQTT_READINGS_TOPIC`: `greenhouse/zones/+/nodes/+/state`
- `MQTT_ACTUATORS_TOPIC`: `greenhouse/zones/+/actuator/status`
- node config topic: `greenhouse/nodes/{node_id}/config`
- node config ack topic: `greenhouse/nodes/{node_id}/config_ack`
- `MQTT_COMMAND_TOPIC`: `greenhouse/zones/{zone_id}/actuator/command`
- `MQTT_CONFIG_TOPIC`: `greenhouse/system/config/current`

## Source Of Truth

- PostgreSQL is authoritative for crop profiles, Zones, Node assignments, logical irrigation lines, watering history, faults, and node config sync status.
- MQTT retained node state is the live transport layer for sleeping devices and the Python controller's working input.
- `nodes.zone_id` is authoritative for routing. `reported_zone_id` from node payloads is stored for visibility only.
- Actuation is external to this Rails app. Rails publishes zone-topic actuator commands with `node_id` for plant-level watering and consumes actuator status messages that include both `zone_id` and `node_id` when available.

## Consumed Payloads

Node state:

```json
{
  "schema_version": "node-state/v1",
  "timestamp": "2026-02-06T12:00:00Z",
  "zone_id": "zone1",
  "node_id": "pico-w-zone1",
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
  "publish_reason": "scheduled",
  "command_message_id": null,
  "lora_sequence": null
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
  "node_id": "pico-w-zone1",
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
2. Rails resolves the reported Node and its CropProfile, then checks that
   Node's completed runtime against that crop's `daily_max_runtime_sec`
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

Changing a Node's crop, calibration, or logical irrigation line publishes its
node-specific config payload to `greenhouse/nodes/{node_id}/config`. Production
Nodes belong to a Zone and are not normally unassigned; legacy reconciliation is
not a normal setup workflow. Rails tracks the desired config, the last Config
Acknowledged payload, and the config sync status on each Node record.

Changing a Node's CropProfile or editing a CropProfile republishes node config for its directly associated Nodes.

In `Settings`, `Save` writes connection settings to PostgreSQL. `Publish Config` broadcasts the current saved Node crop, Zone schedule, and supported actuator topology so the Python controller and nodes can pick up the latest policy immediately.

## MQTT Consumer

Run:

```bash
bin/mqtt_consumer
```

It subscribes to node state and actuator-status topics and enqueues the matching ingest jobs.

When broker auth is enabled, Rails uses `mqtt_username` and `mqtt_password` from `ConnectionSetting`, falling back to `MQTT_USERNAME` and `MQTT_PASSWORD` from the environment.

Empty retained clears are ignored cleanly.

Production provisioning creates a Zone and its four Nodes before telemetry.
Known Nodes reconcile state by `node_id`; their database Zone, crop, logical
line, and custom name remain authoritative. Unknown telemetry is logged and
ignored rather than creating an unassigned production Node.
Automatic watering decisions are made by the Python controller, not by Rails.

The setup API and browser onboarding use `SensorZoneProvisioner` as the sole
production topology authority. A sensor package identity produces exactly
`{package}-ch0` through `{package}-ch3`; the Pico receives those backend-issued
IDs over USB and must acknowledge the exact applied set. Identity values are not
sanitized or truncated: firmware-visible Zone and Node IDs are limited to 31
bytes, package IDs to 27 bytes, and identities use only ASCII letters, digits,
hyphen, and underscore.

Operator pages:

- setup checklist: `/onboarding`
- health dashboard: `/health`
- reading history: `/reading_history`
- watering events: `/watering_events`
- settings: `/settings`

## Retention

`sensor_readings`, `watering_events`, `actuator_statuses`, and `faults` are historical tables. The app does not yet prune them automatically, so long-running Pi installs should define an archival or retention policy.
