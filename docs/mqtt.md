# Victory Garden MQTT Contract

This document defines the canonical MQTT transport used by the Pico nodes, the Python controller, and the Rails control plane.

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
| `greenhouse/zones/{zone_id}/nodes/{node_id}/state` | sensor node | Rails, Python controller | yes | latest node reading and telemetry |
| `greenhouse/zones/{zone_id}/command` | Rails, Python controller | sensor node | yes | retained `request_reading` reread command |
| `greenhouse/zones/{zone_id}/command_ack` | sensor node | Rails, operators | yes | acknowledgement of handled or ignored node command |
| `greenhouse/nodes/{node_id}/config` | Rails | sensor node | yes | retained node assignment and crop config |
| `greenhouse/nodes/{node_id}/config_ack` | sensor node | Rails | yes | acknowledgement of applied or rejected node config |
| `greenhouse/zones/{zone_id}/actuator/command` | Python controller, Rails manual ops | actuator Pico node | no | start or stop watering |
| `greenhouse/zones/{zone_id}/actuator/status` | actuator Pico node | Rails | no | watering progress or fault |
| `greenhouse/system/actuator/config/current` | Rails | actuator Pico node | yes | retained shared actuator topology, line count, and zone-to-line mapping |
| `greenhouse/zones/{zone_id}/controller/event` | Python controller | operators | no | decision summary for a watering pass |
| `greenhouse/zones/{zone_id}/controller/skip` | Python controller | operators | no | skipped-decision summary |
| `greenhouse/zones/{zone_id}/controller/moisture_percent` | Python controller | operators | no | latest controller input moisture |
| `greenhouse/zones/{zone_id}/controller/action` | Python controller | operators | no | `water` or `none` |
| `greenhouse/zones/{zone_id}/controller/runtime_seconds_today` | Python controller | operators | no | cumulative runtime for the zone today |
| `greenhouse/zones/{zone_id}/controller/skip_reason` | Python controller | operators | no | machine-readable skip reason such as cooldown, stale-reading, or quorum failure |
| `greenhouse/system/config/current` | Rails | Python controller | yes | retained crop and zone policy broadcast |

## Canonical Payloads

### Node State

Topic:

`greenhouse/zones/{zone_id}/nodes/{node_id}/state`

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
- `command_message_id`: nullable command correlation id, present when a state
  payload is the result of a command such as LoRa `request_reading`
- `lora_sequence`: nullable LoRa transmit sequence, present when a LoRa result
  echoes the gateway's compact command `sq`

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
  "publish_reason": "interval",
  "command_message_id": null,
  "lora_sequence": null
}
```

Compatibility note:

- Rails and Python still accept the legacy `rssi` field as an alias for `wifi_rssi`
- canonical publishers should emit `wifi_rssi`
- multi-sensor zones should publish only to the per-node retained topic so each sensor's latest reading survives broker and controller restarts

### LoRa Gateway Bridge

The LoRa path is a transport boundary. The radio wire frames should stay compact
and bounded; the Pi gateway translates valid LoRa frames into the canonical MQTT
payloads described in this document.

For the full LoRa protocol, including outbound command, compact reading-result,
and future acknowledgement frames, see:

- [`lora.md`](lora.md)

Inbound physical flow:

1. the Pico sends one UTF-8 JSON object followed by `\n` over UART to its DX-LR22 radio
2. the Pi-connected DX-LR22 receives the bytes through its USB serial adapter
3. `victory-garden-lora-receiver.service` reassembles newline-delimited frames
4. the receiver validates or translates the JSON frame
5. the receiver publishes canonical MQTT payloads

Receiver rules:

- frame delimiter: newline, `\n`
- CRLF input is accepted; trailing `\r` is stripped before JSON parsing
- maximum frame size: `1024` bytes by default
- malformed JSON, invalid UTF-8, oversized frames, and schema-invalid payloads are dropped and logged
- `zone_id` and `node_id` must be MQTT-safe: letters, numbers, `.`, `_`, and `-`
- the MQTT topic is derived from the validated payload:

```text
greenhouse/zones/{zone_id}/nodes/{node_id}/state
```

Publish behavior:

- QoS: `1`
- retained: yes
- duplicate suppression: exact repeated frames are suppressed within the receiver's recent-frame window

Example LoRa serial frame:

```json
{"t":"state","z":"zone1","n":"sensor-zone1-ch0","mid":"pi-001","mr":2345,"mp":55,"sq":1,"up":123}
```

The line above is transmitted with a trailing newline over LoRa. The gateway
translates it to canonical `node-state/v1` and publishes it to:

```text
greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state
```

Outbound command bridge:

- `victory-garden-lora-receiver.service` subscribes to `greenhouse/nodes/+/lora/command`
- command payloads must validate as `lora-command/v1`
- the `{node_id}` topic segment must match `target_node_id`
- accepted commands are serialized as compact JSON plus trailing newline and written to the Pi-connected LR22 serial stream; this MQTT command publish is non-retained
- if the LR22 serial connection is down, commands are dropped and logged with reason `serial_disconnected`
- `request_reading` commands use at most three gateway attempts, six seconds apart; retries reuse the exact serialized frame and preserve `message_id` and `sq`
- gateway retry state is process-local, so a gateway restart does not replay an outstanding non-retained command
- a correlated result before the Rails deadline acknowledges the command; a late result may be ingested but cannot reverse a terminal timeout

Current scope:

- inbound Pico-to-Pi sensor state is implemented and bench-validated
- outbound Pi-to-Pico `request_reading` command routing is implemented and Pi-service validated
- successful `request_reading` uses the returned state/result as the acknowledgement
- failed Pico-side `request_reading` execution can return `lora-command-ack/v1`
  with `status: "failed"` so Rails can fail the command without waiting for the
  server timeout
- explicit success acknowledgements and durable/adaptive retry handling are
  documented protocol work for future non-result commands

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

### Node Config Acknowledged

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

### Actuator Config

Topic:

`greenhouse/system/actuator/config/current`

Example:

```json
{
  "schema_version": "actuator-config/v1",
  "config_version": "2026-04-07T18:10:00Z",
  "irrigation_line_count": 4,
  "nodes": [
    { "node_id": "sensor-zone1-ch0", "zone_id": "zone1", "irrigation_line": 1, "active": true },
    { "node_id": "sensor-zone1-ch1", "zone_id": "zone1", "irrigation_line": 2, "active": true }
  ],
  "zones": [
    { "zone_id": "zone1", "irrigation_line": 1, "active": true },
    { "zone_id": "zone2", "irrigation_line": 2, "active": true },
    { "zone_id": "zone3", "irrigation_line": 3, "active": false }
  ]
}
```

Behavior:

- published retained
- defines the installed pump/relay output count on the shared actuator controller
- maps each plant node to one pump/relay output through `nodes`
- keeps `zones` as a legacy zone-to-line fallback
- lets the actuator Pico subscribe to exact per-zone command topics such as `greenhouse/zones/zone1/actuator/command`
- zone subscriptions are derived from retained node and zone assignments, not from a wildcard topic
- `active` is currently topology metadata for operators and upstream publishers; the actuator Pico uses `zone_id` to `irrigation_line` mapping and does not reject commands only because `active` is `false`

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
  "node_id": "sensor-zone1-ch0",
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
- `node_id` targets a specific plant pump/relay when the actuator config includes `nodes`
- `idempotency_key` is the correlation key expected back in actuator status

### Actuator Status

Topic:

`greenhouse/zones/{zone_id}/actuator/status`

Example:

```json
{
  "zone_id": "zone1",
  "node_id": "sensor-zone1-ch0",
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
  "runtime_seconds_today": 0,
  "valid_sensor_count": 4,
  "expected_sensor_count": 6,
  "valid_node_ids": ["sensor-a", "sensor-b", "sensor-c", "sensor-d"]
}
```

Related single-value controller topics:

- `greenhouse/zones/{zone_id}/controller/moisture_percent`
- `greenhouse/zones/{zone_id}/controller/action`
- `greenhouse/zones/{zone_id}/controller/runtime_seconds_today`
- `greenhouse/zones/{zone_id}/controller/skip_reason`

Observed `controller/skip_reason` values in the current controller include:

- `cooldown`
- `outside_allowed_hours`
- `insufficient_sensor_quorum`
- `stale_reading`
- `incomplete-reading`
- `same-reading-after-watering`

When node-level watering targets are configured, the Python controller evaluates each node independently using that node's crop profile and publishes actuator commands with `node_id`. The older zone-average path remains available as a fallback when no node targets are configured; in that mode a zone can require a minimum fresh sensor count with `--min-zone-sensor-readings`.

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

- Rails/Postgres is authoritative for zones, crop profiles, node assignments, config sync status, watering history, and faults
- MQTT retained state is the live transport layer for nodes and the controller
- `nodes.zone_id` in Rails is authoritative for routing readings; node-reported `zone_id` is stored as visibility metadata

## Validation Sources

This document is derived from the actual implementation in:

- [contracts/examples/](../contracts/examples)
- [ruby_service/lib/mqtt_client.rb](../ruby_service/lib/mqtt_client.rb)
- [ruby_service/app/jobs/publish_node_config_job.rb](../ruby_service/app/jobs/publish_node_config_job.rb)
- [python_tools/watering/schemas.py](../python_tools/watering/schemas.py)
- [firmware/pico_w_sensor_node/src/topics.c](../firmware/pico_w_sensor_node/src/topics.c)
- [firmware/pico_w_sensor_node/src/mqtt_node.c](../firmware/pico_w_sensor_node/src/mqtt_node.c)
- [firmware/pico_w_actuator_node/src/topics.c](../firmware/pico_w_actuator_node/src/topics.c)
- [firmware/pico_w_actuator_node/src/mqtt_node.c](../firmware/pico_w_actuator_node/src/mqtt_node.c)
