# Victory Garden LoRa Protocol

This document defines the LoRa application contract for Victory Garden.

LoRa is treated as a low-bandwidth serial transport. MQTT remains the canonical
system boundary on the Pi.

## Current Status

Implemented and bench-validated:

- Pico/Pico W -> DX-LR22 -> Pi inbound sensor state
- newline-delimited `node-state/v1` JSON frames
- Pi receiver validation through the shared `SensorReading` model
- MQTT publish to `greenhouse/zones/{zone_id}/nodes/{node_id}/state`
- QoS 1 retained MQTT publish
- USB serial disconnect/reconnect recovery

Not implemented yet:

- Pi -> Pico LoRa command transmit
- Pico command parsing
- Pico -> Pi command acknowledgement
- retry/timeout handling
- message authentication

## Transport Framing

Each LoRa application message is a single UTF-8 JSON object followed by a
newline:

```text
{...json...}\n
```

Receiver behavior:

- `\n` terminates a frame
- CRLF is accepted; a trailing `\r` is stripped before JSON parsing
- default maximum frame size is `1024` bytes
- oversized or malformed frames are dropped and logged

The DX-LR22 radios are used in transparent mode. At the LoRa radio layer this is
shared-air communication; application messages must carry their own target
identity.

## Inbound Sensor State

Inbound sensor state is already implemented.

Schema:

- `schema_version`: `node-state/v1`

Payload shape:

- see [`mqtt.md`](mqtt.md#node-state)

Serial frame example:

```json
{"schema_version":"node-state/v1","timestamp":"2026-08-21T15:20:00Z","zone_id":"zone1","node_id":"lora-bridge-test","moisture_raw":2345,"moisture_percent":55,"health":"ok","last_error":"none","publish_reason":"lora_bridge_ingest_test"}
```

The Pi receiver validates the frame and publishes the exact payload bytes to:

```text
greenhouse/zones/{zone_id}/nodes/{node_id}/state
```

`zone_id` and `node_id` must be MQTT-safe:

- letters
- numbers
- `.`
- `_`
- `-`

## Outbound Command Contract

Outbound command support should use a LoRa-specific command schema rather than
reusing the existing Wi-Fi/MQTT node-command payload directly.

The first supported command should be:

- `request_reading`

### Command Message

Schema:

- `schema_version`: `lora-command/v1`

Required fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `schema_version` | string | Must be `lora-command/v1` |
| `message_id` | string | Unique command id for deduplication, ack correlation, and retry handling |
| `timestamp` | string | UTC ISO 8601 time when the gateway created the command |
| `source` | string | Gateway identity, initially `pi-gateway` |
| `target_node_id` | string | Node that should act on the command |
| `command` | string | Command name |
| `args` | object | Command-specific arguments; empty object for `request_reading` |

Example:

```json
{
  "schema_version": "lora-command/v1",
  "message_id": "pi-20260821T153000Z-abc123",
  "timestamp": "2026-08-21T15:30:00Z",
  "source": "pi-gateway",
  "target_node_id": "sensor-zone1-ch0",
  "command": "request_reading",
  "args": {}
}
```

Node behavior:

- if `schema_version` is not `lora-command/v1`, ignore the frame
- if `target_node_id` does not match the node's configured `node_id`, ignore the frame
- if `message_id` was recently handled, treat it as a duplicate
- if `command` is unsupported, send a rejected acknowledgement
- for `request_reading`, publish a fresh `node-state/v1` frame over LoRa

Ignored non-target commands should not be acknowledged. That avoids an ack storm
when multiple nodes hear the same shared-air LoRa transmission.

### Command Acknowledgement

Schema:

- `schema_version`: `lora-command-ack/v1`

Required fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `schema_version` | string | Must be `lora-command-ack/v1` |
| `message_id` | string | Unique ack message id |
| `timestamp` | string | UTC ISO 8601 time when the node created the ack |
| `source_node_id` | string | Node that handled or rejected the command |
| `target` | string | Ack target, initially `pi-gateway` |
| `ack_for_message_id` | string | Original command `message_id` |
| `status` | string | Command outcome |
| `error` | string or null | Error detail for rejected/failed commands |

Statuses:

- `acknowledged`: command accepted and handled
- `rejected`: command was addressed to this node but invalid or unsupported
- `failed`: command was accepted but failed while executing
- `duplicate`: command was already handled recently

Example:

```json
{
  "schema_version": "lora-command-ack/v1",
  "message_id": "sensor-zone1-ch0-20260821T153001Z-def456",
  "timestamp": "2026-08-21T15:30:01Z",
  "source_node_id": "sensor-zone1-ch0",
  "target": "pi-gateway",
  "ack_for_message_id": "pi-20260821T153000Z-abc123",
  "status": "acknowledged",
  "error": null
}
```

## MQTT Bridge Topics

The Pi gateway should bridge MQTT command requests to LoRa command frames.

Recommended MQTT input topic for LoRa-specific commands:

```text
greenhouse/nodes/{node_id}/lora/command
```

Recommended MQTT output topic for LoRa-specific acks:

```text
greenhouse/nodes/{node_id}/lora/command_ack
```

Why node-specific topics:

- command targeting is explicit
- LoRa command traffic does not blur with existing Wi-Fi/MQTT node commands
- the gateway can derive `target_node_id` from the topic and/or validate it
  against the payload

Initial bridge behavior:

1. subscribe to `greenhouse/nodes/+/lora/command`
2. validate the payload as `lora-command/v1`
3. require the topic node id and `target_node_id` to match
4. serialize the command as compact JSON plus trailing newline
5. write the frame to the Pi-connected LR22 serial port
6. receive `lora-command-ack/v1` over the same serial reader
7. publish the ack to `greenhouse/nodes/{source_node_id}/lora/command_ack`

## Freshness, Deduplication, and Retry Rules

Initial recommended rules:

- `message_id` must be MQTT-safe and unique enough for practical command
  correlation
- nodes remember a small recent set of handled command `message_id`s
- duplicates addressed to the same node should produce `duplicate` or be
  ignored; choose one behavior during implementation and test it explicitly
- commands older than 60 seconds should be rejected if the node has a valid
  clock
- if the node does not have valid time, it may skip age rejection but should
  still deduplicate by `message_id`
- the gateway should treat a command as timed out if no ack arrives within a
  configured window

Retry behavior should be conservative. Repeated command frames consume shared
airtime and can delay sensor-state traffic.

## First Implementation Scope

In scope:

- Pi subscribes to `greenhouse/nodes/+/lora/command`
- Pi validates `lora-command/v1`
- Pi writes newline-delimited command frames to the LR22 serial port
- Pico filters by `target_node_id`
- Pico handles `request_reading`
- Pico emits `lora-command-ack/v1`
- Pi publishes acks to MQTT

Out of scope:

- wildcard/broadcast commands
- multi-hop routing
- durable command queues
- guaranteed delivery
- encryption/signatures
- radio-level addressing
- complex retry policy

## Design Notes

- Transparent LoRa behaves like shared-air broadcast in this setup. Routing is
  application-level filtering, not radio-level routing.
- Inbound sensor state can tolerate dropped frames because a future reading
  refreshes retained MQTT state. Commands and acks need stricter correlation
  because they represent operator intent.
- Message authentication should be revisited before outdoor or multi-node
  production deployment.
