# Victory Garden LoRa Protocol

This document defines the LoRa application contract for Victory Garden.

LoRa is treated as a low-bandwidth serial transport. MQTT remains the canonical
system boundary on the Pi.

Design rule:

- LoRa wire frames should stay compact and bounded.
- The Pi gateway translates compact LoRa frames into canonical MQTT payloads.
- MQTT topics and payloads remain the stable integration contract for the rest
  of the Victory Garden system.
- For `request_reading`, the returned sensor-state result is the acknowledgement
  of the command.
- Explicit acknowledgement frames are reserved for commands that do not
  naturally return a result payload.

## Current Status

Implemented and bench-validated:

- Pico W sensor firmware -> DX-LR22 -> Pi inbound sensor state
- newline-delimited JSON frames
- Pi receiver validation through the shared `SensorReading` model
- MQTT publish to `greenhouse/zones/{zone_id}/nodes/{node_id}/state`
- QoS 1 retained MQTT publish
- USB serial disconnect/reconnect recovery
- compact Pico -> Pi autonomous state frames
- gateway translation from compact LoRa state/result frames into canonical
  `node-state/v1` MQTT payloads
- sensor firmware preserves the normal boot/read/transmit/sleep rhythm when
  LoRa is enabled
- basic sensor-side LoRa transmit failure handling is bounded and visible in
  USB serial logs
- sensor-firmware runtime receive/dispatch for Pi -> Pico LoRa commands
- end-to-end Pi -> Pico `request_reading` command handling over LoRa

Not implemented yet:

- explicit acknowledgements for commands that do not return result payloads
- durable retry/timeout handling across gateway restarts
- sensor-side detection that the gateway actually heard autonomous telemetry
- receive-while-sleeping / LR22 air wake-up behavior
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

Inbound sensor state is the canonical MQTT payload after gateway translation.
The LoRa wire frame may be compact; MQTT remains `node-state/v1`.

Schema:

- `schema_version`: `node-state/v1`

Payload shape:

- see [`mqtt.md`](mqtt.md#node-state)

Canonical MQTT payload example:

```json
{"schema_version":"node-state/v1","timestamp":"2026-08-21T15:20:00Z","zone_id":"zone1","node_id":"lora-bridge-test","moisture_raw":2345,"moisture_percent":55,"health":"ok","last_error":"none","publish_reason":"lora_bridge_ingest_test"}
```

The Pi receiver validates or translates the inbound LoRa frame, then publishes a
canonical `node-state/v1` payload to:

```text
greenhouse/zones/{zone_id}/nodes/{node_id}/state
```

`zone_id` and `node_id` must be MQTT-safe:

- letters
- numbers
- `.`
- `_`
- `-`

### Autonomous Sensor Telemetry

The sensor firmware can send compact LoRa state frames during the normal sensor
cycle. This is best-effort telemetry; it does not wait for a telemetry
acknowledgement.

The current sensor Pico sends one compact frame per ADS1115 channel when soil is
read. The compact frame includes:

| Field | Type | Purpose |
| --- | --- | --- |
| `t` | string | Compact type, currently `state` |
| `z` | string | Zone id |
| `n` | string | Channel node id, for example `sensor-zone1-ch0` |
| `mid` | string | Sensor-generated message id for this reading |
| `mr` | integer | Moisture raw reading |
| `mp` | integer or null | Moisture percent, if known |
| `at` | number | Air temperature C when the SHT40 read succeeds |
| `h` | number | Humidity percent when the SHT40 read succeeds |
| `r` | string | Publish reason, for example `boot` or `interval` |
| `sq` | integer | Sensor-generated LoRa sequence for this channel reading |
| `up` | integer | Pico uptime seconds |

Example compact autonomous frame:

```json
{"t":"state","z":"zone1","n":"sensor-zone1-ch0","mid":"sensor-zone1-ch0-w5-c0","mr":15218,"mp":42,"at":25.64,"h":57.3,"r":"boot","sq":17,"up":29}
```

Gateway translation rules:

- expand `z` to canonical `zone_id`
- expand `n` to canonical `node_id`
- expand `mr` / `mp` to `moisture_raw` / `moisture_percent`
- expand `at` / `h` to `air_temperature_c` / `humidity_percent`
- expand `r` to `publish_reason`; default to `request_reading` only for older
  compact frames without `r`
- preserve `sq` as canonical `lora_sequence`
- include `command_message_id` only when `publish_reason` is `request_reading`

The Pico logs a per-cycle LoRa summary over USB serial:

```text
[lora] cycle summary ready=true sent=4 failures=0 available=true
```

If a local LoRa send fails, the Pico skips remaining LoRa sends for that wake
cycle and continues the normal MQTT/sensor/sleep flow. Without telemetry ACKs,
the Pico cannot know whether the Pi gateway heard a frame after the LR22 module
accepts it locally.

## Outbound Command Contract

Outbound command support uses a canonical MQTT command at the gateway boundary
and a compact LoRa command on the radio boundary. The gateway validates the full
MQTT payload first, then translates it to the compact wire frame before writing
to the LR22 serial port.

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

### Compact Command Wire Frame

The Pi writes the compact command form over LoRa:

```json
{"t":"cmd","c":"rr","n":"sensor-zone1-ch0","mid":"pi-20260821T153000Z-abc123","sq":1}
```

Fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `t` | string | Compact type, currently `cmd` |
| `c` | string | Compact command code; `rr` means `request_reading` |
| `n` | string | Target node id |
| `mid` | string | Original canonical MQTT `message_id` |
| `sq` | integer | Optional gateway-owned LoRa transmit sequence |

Node behavior:

- if compact `t` is not `cmd`, ignore the frame
- if compact `n` does not match the node's configured `node_id`, ignore the frame
- if `command` is unsupported, send a compact rejected acknowledgement once
  explicit ack frames are implemented
- for `request_reading`, take a fresh reading for the targeted channel, send a
  compact state/result frame over LoRa, and include the original `mid` as the
  correlation id
- if compact `sq` is present, echo it in the compact state/result frame

Ignored non-target commands should not be acknowledged. That avoids an ack storm
when multiple nodes hear the same shared-air LoRa transmission.

Current sensor firmware handles commands during bounded awake windows only. It
does not receive LoRa commands while sleeping. The gateway should therefore
retry `request_reading` commands within its bounded retry policy, and future
low-power wake-on-demand work should add LR22 air wake-up behavior explicitly.
After boot or interval telemetry, the Pico opens a short post-telemetry command
window before returning to sleep so gateway commands do not have to race the
autonomous transmit burst.
The Pico suppresses duplicate copies of the same LoRa command while it is
pending and after a successful response, so gateway retries do not trigger
multiple readings for the same `message_id`/target/sequence.

If a Pico sends a `request_reading` result during a wake cycle, it suppresses
the normal autonomous LoRa telemetry for the rest of that same cycle. Wi-Fi/MQTT
publishing continues normally. This avoids a command response colliding with
immediate boot or interval LoRa telemetry on the shared radio.

### Compact Reading Result

`request_reading` does not require a separate acknowledgement frame. The reading
result is the acknowledgement.

The compact LoRa result frame should carry the smallest practical field set
needed for the gateway to build the canonical MQTT state payload.

Required fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `t` | string | Compact type, initially `state` |
| `z` | string | Zone id |
| `n` | string | Node id |
| `mid` | string | Original command `message_id` for correlation |
| `mr` | integer | Moisture raw reading |
| `mp` | integer or null | Moisture percent, if known |
| `sq` | integer | Optional echoed LoRa transmit sequence |
| `up` | integer | Pico uptime seconds |

Example compact LoRa result frame:

```json
{"t":"state","z":"zone1","n":"sensor-zone1-ch0","mid":"pi-001","mr":2345,"mp":55,"sq":1,"up":123}
```

Gateway behavior:

- validate the compact LoRa frame
- require `t` to be `state`
- require `z`, `n`, and `mid` to be MQTT-safe
- expand the result into canonical `node-state/v1`
- publish the canonical payload to
  `greenhouse/zones/{zone_id}/nodes/{node_id}/state`
- set `publish_reason` to `request_reading`
- preserve `mid` as canonical `command_message_id`
- preserve `sq`, when present, as canonical `lora_sequence`

### Explicit Command Acknowledgement

Successful `request_reading` commands do not use explicit acknowledgements
because the result frame is already proof that the command was received and
handled.

If the Pico receives a `request_reading` command but cannot return the correlated
state/result frame, it may send a `lora-command-ack/v1` frame with
`status: "failed"` and a machine-readable `error`. The gateway forwards that ACK
to MQTT, and Rails maps the matching command to its existing terminal failure
state.

Ack frames also remain part of the protocol for future commands that do not
naturally return a result payload, such as configuration changes or actuator
commands. The current Pico firmware sends the canonical ACK JSON shape directly
on the LoRa wire for failure ACKs because this is an uncommon error path and
keeps gateway translation simple. A compact ACK form can still be added later if
airtime pressure makes it worthwhile.

Canonical MQTT ack schema:

- `schema_version`: `lora-command-ack/v1`

Canonical MQTT ack fields:

| Field | Type | Purpose |
| --- | --- | --- |
| `schema_version` | string | Must be `lora-command-ack/v1` |
| `message_id` | string | Unique ack message id |
| `timestamp` | string | UTC ISO 8601 time when the node created the ack or when the gateway translated it |
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

Canonical MQTT ack example:

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

Rails sends `request_reading` commands to this LoRa topic only for nodes whose
`communication_transport` is explicitly set to `lora`. Existing nodes default
to `wifi`, and `auto` currently remains on the Wi-Fi path until automatic
transport selection is defined.

Recommended MQTT output topic for LoRa-specific acks:

```text
greenhouse/nodes/{node_id}/lora/command_ack
```

Recommended MQTT output topic for gateway command routing status:

```text
greenhouse/lora/gateway/command_status
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
5. stamp the compact command with a process-local LoRa sequence `sq`
6. write the frame to the Pi-connected LR22 serial port
7. publish a non-retained `lora-command-route-status/v1` event describing
   whether the gateway routed or rejected the command
8. receive a compact LoRa result frame over the same serial reader
9. translate the compact result into canonical `node-state/v1`
10. publish the state to `greenhouse/zones/{zone_id}/nodes/{node_id}/state`

For future commands that do not produce a result payload, the gateway should
translate compact ack/result frames into:

```text
greenhouse/nodes/{node_id}/lora/command_ack
```

## Freshness, Deduplication, and Retry Rules

Initial recommended rules:

- `message_id` must be MQTT-safe and unique enough for practical command
  correlation
- gateway compact command `sq` is a process-local LoRa transmit sequence used
  for debugging ordering/retry behavior; it is not a deduplication key
- production node firmware remembers a small in-memory set of recently handled
  LoRa commands
- duplicates addressed to the same node are ignored while pending and after a
  successful response
- commands older than 60 seconds should be rejected if the node has a valid
  clock
- if the node does not have valid time, it may skip age rejection but should
  still deduplicate by `message_id`

Command completion depends on command type:

| Command type | Completion signal | Timeout meaning |
| --- | --- | --- |
| `request_reading` | correlated `node-state/v1` payload with matching `command_message_id` | no correlated reading reached the server before the command timeout |
| future actuator/config commands | correlated `lora-command-ack/v1` payload with matching `ack_for_message_id` | no ACK reached the server before the command timeout |

The Rails command timeout is the server-side guardrail. It should remain longer
than the gateway retry window so the gateway can finish its bounded attempts
before the server records the command as timed out. The current request-reading
job uses a 30-second timeout, while the gateway default is three total transmit
attempts with a six-second retry delay.

Gateway command route status events are diagnostic transport events. A
`routed` status means the gateway accepted the MQTT command and wrote the
compact frame to the LR22 serial stream. A `failed` status means the gateway
rejected or could not route the command, with `reason` describing the failure
such as `serial_disconnected`, invalid payload, oversized frame, or
`retry_exhausted`. These events do not replace Pico result/ACK completion; they
make gateway-side failures visible sooner than the server timeout.

Rails subscribes to `greenhouse/lora/gateway/command_status`. Failed route
events with a matching `message_id` move the corresponding non-terminal
`NodeCommand` to the existing terminal failure state, `timeout`, and record a
`LORA_COMMAND_ROUTE_FAILED` fault. Routed events are diagnostic only and do not
complete the command; completion still requires the Pico result or ACK.

Retry behavior should be conservative. Repeated command frames consume shared
airtime and can delay sensor-state traffic. The current gateway defaults to
three total transmit attempts with a six-second retry delay. Retries reuse the
same compact command frame bytes, including the original `sq`, so the Pico sees
repeated copies of one command rather than distinct commands. The Pico keeps a
small in-memory cache of recently completed LoRa commands and ignores exact
duplicates after a successful response.

## First Implementation Scope

In scope:

- Pi subscribes to `greenhouse/nodes/+/lora/command`
- Pi validates `lora-command/v1`
- Pi writes newline-delimited compact command frames to the LR22 serial port
- Pico filters by compact target node id
- Pico handles `request_reading`
- Pico emits one compact state/result frame for `request_reading`
- Pico emits `lora-command-ack/v1` with `status: "failed"` if it received
  `request_reading` but could not return the state/result frame
- Pi translates compact state/result frames into canonical MQTT `node-state/v1`
- Pi retries `request_reading` commands until the correlated state result is
  published or the bounded attempt limit is reached

Out of scope:

- explicit success ack frames for commands that produce result payloads
- explicit ack handling for future commands that do not produce result payloads
- wildcard/broadcast commands
- multi-hop routing
- durable command queues
- guaranteed delivery
- encryption/signatures
- radio-level addressing
- durable or adaptive retry policy

## Design Notes

- Transparent LoRa behaves like shared-air broadcast in this setup. Routing is
  application-level filtering, not radio-level routing.
- Inbound sensor state can tolerate dropped frames because a future reading
  refreshes retained MQTT state. Commands need stricter correlation because
  they represent operator intent.
- Verbose JSON is appropriate at MQTT and database boundaries. The radio path is
  constrained, so LoRa wire frames should be compact and translated at the
  gateway.
- Message authentication should be revisited before outdoor or multi-node
  production deployment.
