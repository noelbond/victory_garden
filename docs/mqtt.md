# Victory Garden MQTT Contract

This document defines the canonical MQTT transport used by the Pico/Arduino nodes, the Python controller, and the Rails control plane.

## Conventions

- Topic namespace: `greenhouse/*`
- Zone topics are keyed by `zone_id`
- Node config topics are keyed by `node_id`
- Payloads are JSON unless the table below says otherwise
- Timestamps use UTC ISO 8601, for example `2026-03-30T20:53:59Z`
- Retained topics are used only where replay-on-reconnect is intentional
- The deployed Pi stack uses MQTT username/password authentication on the local broker

Outside MQTT itself, the Pi also exposes a small UDP discovery responder on `MQTT_DISCOVERY_PORT`. Pico nodes use it only when their saved broker IP is stale so they can learn the Pi's current IP and then reconnect over normal MQTT.

## Topic Summary

| Topic | Producer | Consumer | Retained | Purpose |
|---|---|---|---|---|
| `greenhouse/zones/{zone_id}/state` | sensor node | Rails, Python controller | yes | latest node reading and telemetry |
| `greenhouse/zones/{zone_id}/command` | Rails, Python controller | sensor node | yes | retained `request_reading` reread command |
| `greenhouse/zones/{zone_id}/command_ack` | sensor node | Rails, operators | yes | acknowledgement of handled or ignored node command |
| `greenhouse/nodes/{node_id}/config` | Rails | sensor node | yes | retained node assignment and crop config |
| `greenhouse/nodes/{node_id}/config_ack` | sensor node | Rails | yes | acknowledgement of applied or rejected node config |
| `greenhouse/zones/{zone_id}/actuator/command` | Python controller, Rails manual ops | actuator Pico node | no | start or stop watering |
| `greenhouse/zones/{zone_id}/actuator/status` | actuator Pico node | Rails | no | watering progress or fault |
| `greenhouse/zones/{zone_id}/controller/event` | Python controller | operators | no | decision summary for a watering pass |
| `greenhouse/zones/{zone_id}/controller/skip` | Python controller | operators | no | skipped-decision summary |
| `greenhouse/zones/{zone_id}/controller/moisture_percent` | Python controller | operators | no | latest controller input moisture |
| `greenhouse/zones/{zone_id}/controller/action` | Python controller | operators | no | `water` or `none` |
| `greenhouse/zones/{zone_id}/controller/runtime_seconds_today` | Python controller | operators | no | cumulative runtime for the zone today |
| `greenhouse/zones/{zone_id}/controller/skip_reason` | Python controller | operators | no | duplicate-read or cooldown reason |
| `greenhouse/system/config/current` | Rails | Python controller | yes | retained crop and zone policy broadcast |

## Canonical Payloads

### Node State

Topic:

`greenhouse/zones/{zone_id}/state`

Schema:

- `schema_version`: `node-state/v1`
- `timestamp`: UTC ISO 8601
- `zone_id`: node-reported zone identifier
- `node_id`: unique node identifier
- `moisture_raw`: integer raw reading
- `moisture_percent`: normalized `0..100`, nullable during partial data
- `soil_temp_c`: nullable float
- `battery_voltage`: nullable float
- `battery_percent`: nullable integer `0..100`
- `wifi_rssi`: nullable integer dBm
- `uptime_seconds`: nullable integer
- `wake_count`: nullable integer
- `ip`: nullable string IPv4
- `health`: nullable string such as `ok` or `degraded`
- `last_error`: nullable string or `none`
- `publish_reason`: nullable string such as `scheduled`, `interval`, or `request_reading`

Example:

```json
{
  "schema_version": "node-state/v1",
  "timestamp": "2026-03-30T20:53:59Z",
  "zone_id": "zone1",
  "node_id": "pico-w-zone1",
  "moisture_raw": 615,
  "moisture_percent": 85,
  "soil_temp_c": null,
  "battery_voltage": null,
  "battery_percent": null,
  "wifi_rssi": -42,
  "uptime_seconds": 316,
  "wake_count": 316,
  "ip": "192.168.4.40",
  "health": "ok",
  "last_error": "none",
  "publish_reason": "interval"
}
```

Compatibility note:

- Rails and Python still accept the legacy `rssi` field as an alias for `wifi_rssi`
- canonical publishers should emit `wifi_rssi`

### Node Command

Topic:

`greenhouse/zones/{zone_id}/command`

Current supported command:

- `request_reading`

Example:

```json
{
  "schema_version": "node-command/v1",
  "command": "request_reading",
  "command_id": "zone1-20260330T210000Z-reread"
}
```

Behavior:

- published retained
- node handles the command, publishes `command_ack`, then clears the retained command topic with an empty retained payload

### Node Command Ack

Topic:

`greenhouse/zones/{zone_id}/command_ack`

Example:

```json
{
  "schema_version": "node-command-ack/v1",
  "zone_id": "zone1",
  "node_id": "pico-w-zone1",
  "command": "request_reading",
  "command_id": "zone1-20260330T210000Z-reread",
  "status": "acknowledged"
}
```

Observed status values:

- `acknowledged`
- `ignored`

### Node Config

Topic:

`greenhouse/nodes/{node_id}/config`

Example assigned payload:

```json
{
  "schema_version": "node-config/v1",
  "config_version": "2026-03-30T21:10:00Z",
  "issued_at": "2026-03-30T21:10:00Z",
  "node_id": "pico-w-zone1",
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

Example unassigned payload:

```json
{
  "schema_version": "node-config/v1",
  "config_version": "2026-03-30T21:10:00Z",
  "issued_at": "2026-03-30T21:10:00Z",
  "node_id": "pico-w-zone1",
  "assigned": false,
  "zone": null,
  "crop": null
}
```

Behavior:

- published retained
- `config_version` is the idempotency key for config application
- nodes should not rewrite flash if the same retained `config_version` is replayed

### Node Config Ack

Topic:

`greenhouse/nodes/{node_id}/config_ack`

Example:

```json
{
  "schema_version": "node-config-ack/v1",
  "node_id": "pico-w-zone1",
  "config_version": "2026-03-30T21:10:00Z",
  "status": "applied",
  "timestamp": "2026-03-30T21:10:03Z",
  "zone_id": "zone1",
  "applied_config": {
    "assigned": true,
    "zone_id": "zone1",
    "crop_id": "tomato"
  },
  "error": null
}
```

Observed status values:

- `applied`
- `error`

### Actuator Command

Topic:

`greenhouse/zones/{zone_id}/actuator/command`

Commands:

- `start_watering`
- `stop_watering`

Example start command:

```json
{
  "command": "start_watering",
  "zone_id": "zone1",
  "runtime_seconds": 45,
  "reason": "manual_trigger",
  "issued_at": "2026-03-30T22:00:53Z",
  "idempotency_key": "zone1-20260330T220053Z-efeaa58a"
}
```

Example stop command:

```json
{
  "command": "stop_watering",
  "zone_id": "zone1",
  "runtime_seconds": null,
  "reason": "manual_stop",
  "issued_at": "2026-03-30T22:03:00Z",
  "idempotency_key": "zone1-20260330T220300Z-4d4d70c8"
}
```

Rules:

- `runtime_seconds` must be present and `> 0` for `start_watering`
- `runtime_seconds` must be `null` for `stop_watering`
- `idempotency_key` is the correlation key expected back in actuator status

### Actuator Status

Topic:

`greenhouse/zones/{zone_id}/actuator/status`

Example:

```json
{
  "zone_id": "zone1",
  "state": "COMPLETED",
  "timestamp": "2026-03-30T22:01:38Z",
  "idempotency_key": "zone1-20260330T220053Z-efeaa58a",
  "actual_runtime_seconds": 45,
  "flow_ml": 820,
  "fault_code": null,
  "fault_detail": null
}
```

Observed `state` values:

- `ACKNOWLEDGED`
- `RUNNING`
- `COMPLETED`
- `STOPPED`
- `FAULT`

### Controller Event

Topic:

`greenhouse/zones/{zone_id}/controller/event`

Example:

```json
{
  "zone_id": "zone1",
  "timestamp": "2026-03-30T19:41:42.582461+00:00",
  "moisture_percent": 86.0,
  "action": "none",
  "runtime_seconds": 0,
  "runtime_seconds_today": 0
}
```

Related single-value controller topics:

- `greenhouse/zones/{zone_id}/controller/moisture_percent`
- `greenhouse/zones/{zone_id}/controller/action`
- `greenhouse/zones/{zone_id}/controller/runtime_seconds_today`
- `greenhouse/zones/{zone_id}/controller/skip_reason`

## Retained Message Rules

Use retained messages only for:

- latest node state
- latest reread command
- latest node config
- latest node config ack
- latest node command ack

Do not retain:

- actuator commands
- actuator status
- controller decision events

Clearing retained topics:

- nodes clear handled `greenhouse/zones/{zone_id}/command` by publishing an empty retained payload
- consumers must ignore empty retained clears cleanly

## Source Of Truth Boundaries

- Rails/Postgres is authoritative for zones, crop profiles, node claims, config sync status, watering history, and faults
- MQTT retained state is the live transport layer for nodes and the controller
- `nodes.zone_id` in Rails is authoritative for routing readings; node-reported `zone_id` is stored as visibility metadata

## Validation Sources

This document is derived from the actual implementation in:

- [`contracts/examples/`](/Users/noel/coding/python/victory_garden/contracts/examples)
- [`ruby_service/lib/mqtt_client.rb`](/Users/noel/coding/python/victory_garden/ruby_service/lib/mqtt_client.rb)
- [`ruby_service/app/jobs/publish_node_config_job.rb`](/Users/noel/coding/python/victory_garden/ruby_service/app/jobs/publish_node_config_job.rb)
- [`python_tools/watering/schemas.py`](/Users/noel/coding/python/victory_garden/python_tools/watering/schemas.py)
- [`firmware/pico_w_sensor_node/src/topics.c`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/topics.c)
- [`firmware/pico_w_sensor_node/src/mqtt_node.c`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/mqtt_node.c)
- [`firmware/pico_w_actuator_node/src/topics.c`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/src/topics.c)
- [`firmware/pico_w_actuator_node/src/mqtt_node.c`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/src/mqtt_node.c)
