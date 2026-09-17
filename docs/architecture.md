# Victory Garden Architecture

Victory Garden is a local-first automated watering system built around MQTT, a Raspberry Pi, and microcontroller nodes for sensing and actuation.

The current deployment model is one Raspberry Pi running the broker, control plane, database, and Python controller on the same LAN as the nodes.

## Product Topology

A Zone represents one provisioned sensor Pico/package and a growing location. A
Zone has four stable sensor-position Nodes (`ch0` through `ch3`); it groups
those Nodes but does not own a crop.

A Node represents one plant/sensor position. It belongs to one Zone, owns its
optional CropProfile, and owns its logical, greenhouse-wide `irrigation_line`.
Nodes can therefore use different crops within the same Zone. A crop-less Node
may receive telemetry during setup but is not eligible for crop-derived
watering. Its default display name is derived from the Zone and channel (for
example, `Tomatoes Node 1`); a stored Node name is a user-customized override.

Provisioning establishes the Zone, package identity, four Node identities, and
logical irrigation-line assignments before telemetry arrives. The sensor
firmware receives those backend-issued identities. MQTT state reconciles known
topology; it is not the production source for creating unassigned Nodes.

The dedicated actuator Pico is one greenhouse-wide production controller. It
routes a command through the retained Node topology and each Node's logical
irrigation line, not through Zone ownership. A logical assignment can exceed
the currently installed output count without being changed; unsupported outputs
are excluded from actuator topology and fail closed until capacity is added.
Sensor channel and irrigation line are intentionally separate concepts.

## Runtime Components

### Sensor nodes

Supported node implementations in this repo:

- native Raspberry Pi Pico W firmware

Node responsibilities:

- read soil moisture
- publish retained `node-state/v1` payloads to `greenhouse/zones/{zone_id}/nodes/{node_id}/state`
- consume retained `request_reading` commands from `greenhouse/zones/{zone_id}/command`
- consume retained `node-config/v1` messages from `greenhouse/nodes/{node_id}/config`
- publish command and config acknowledgements

### Actuator nodes

Supported actuator implementation in this repo:

- native Raspberry Pi Pico W actuator firmware

Actuator node responsibilities:

- consume greenhouse-wide `greenhouse/zones/+/actuator/command`
- publish `greenhouse/zones/{zone_id}/actuator/status`
- consume retained global Node-to-line actuator topology
- drive the supported relay output for the addressed Node
- enforce the requested runtime cutoff locally on the actuator Pico

### Mosquitto

Mosquitto is the message transport hub.

It carries:

- retained node state
- retained reread commands
- retained node config and config acknowledgements
- non-retained actuator commands and status
- controller telemetry topics

The Pi also runs a small UDP broker-discovery responder so Pico nodes can recover automatically when the Pi's LAN IP changes.

### Rails control plane

Rails is the configuration authority, persistence layer, and operator UI.

It is responsible for:

- crop profiles, Zone grouping, and Node configuration
- node assignment and node config publication
- historical persistence in PostgreSQL
- MQTT ingest for node state, actuator status, and node config acknowledgements
- MQTT ingest for Python controller events so automatic watering history is persisted
- manual watering commands
- delayed reread scheduling after completed watering
- operator UI, including the Setup Checklist, Reading History, Health, and Watering Events pages

Important routing rule:

- `nodes.zone_id` in PostgreSQL is authoritative
- a node's reported `zone_id` is diagnostic only

### Python tools

Python fills one live role:

- automatic controller

The Python controller:

- consumes retained node state
- consumes retained `greenhouse/system/config/current` as its live Node crop and Zone schedule policy source
- decides when automatic watering should run
- publishes `greenhouse/zones/{zone_id}/actuator/command`
- publishes controller event and skip telemetry

Rails is no longer the automatic actuator-command publisher.

## Main Flows

### Automatic watering flow

1. A node publishes retained `node-state/v1`.
2. Rails MQTT consumer enqueues `SensorIngestJob`.
3. `SensorIngestor` normalizes the payload, updates the `Node`, and persists a `SensorReading`.
4. The Python controller consumes the same retained node state and evaluates that Node using its Node crop assignment, Zone schedule metadata, and the latest Rails-published system config. Crop-less or capacity-unsupported Nodes fail closed.
5. If watering is needed, Python publishes `start_watering` and emits a controller event containing the `idempotency_key`.
6. Rails ingests that controller event and persists a `WateringEvent` with status `queued`.
7. The actuator Pico runs the command and publishes status updates.
8. Rails ingests actuator status, updates the event, records faults when needed, and schedules a delayed reread after `COMPLETED`.
9. `RequestReadingJob` publishes a retained `request_reading` command back to the node.

### Manual watering flow

1. An operator triggers `Water Now` in Rails for a selected Node.
2. Rails creates a `WateringEvent`.
3. Rails publishes the actuator command.
4. The actuator Pico reports progress or faults.
5. Rails updates the event and health/fault state.

### Node config flow

1. Rails publishes retained `node-config/v1`.
2. The node applies or rejects it.
3. The node publishes retained `node-config-ack/v1`.
4. Rails ingests the acknowledgement and updates node config-sync state.

## Source Of Truth

### PostgreSQL in Rails is authoritative for

- crop profiles
- zones
- assigned node-to-zone mapping
- Node crop and logical irrigation-line assignments
- config sync state
- persisted sensor readings
- watering events
- actuator statuses
- faults

### MQTT retained topics are authoritative only for wake-and-replay transport

- latest node state
- latest node reread command
- latest node config
- latest node command ack
- latest node config ack

They are transport state, not the long-term system of record.

## Single-Pi Deployment

The intended local deployment is one Raspberry Pi running:

- Mosquitto
- Rails web app
- Rails MQTT consumer
- PostgreSQL
- Python controller

With separate networked nodes on the same LAN:

- one or more provisioned sensor Pico/packages (four Nodes each)
- one dedicated greenhouse-wide actuator Pico for supported outputs

The combined sensor-and-actuator firmware is retained for demonstration,
development, and end-to-end support. It is not the production greenhouse-wide
actuator topology.

The default Pi install also provisions MQTT broker authentication, shares the broker credentials with Rails and the Python services through `/etc/victory_garden.env`, and exposes `MQTT_DISCOVERY_PORT` for Pico broker rediscovery.

Useful endpoints:

- app UI: `http://<pi-ip>:3000`
- liveness: `http://<pi-ip>:3000/up`
- operator health: `http://<pi-ip>:3000/health`

## Current Project Status

- the production topology is backend-provisioned sensor packages plus one greenhouse-wide dedicated actuator controller
- Python now owns automatic watering decisions and consumes Rails-published live config
- Rails persists automatic watering history from Python controller events and remains the manual/operator surface
- dedicated actuator admission preserves duplicate/key-conflict handling, freshness checks, a local runtime cutoff, STOP correlation, journal fail-closed behavior, and early boot/reset safe-OFF output drive
- final physical actuator capacity and hardware behavior have not been validated; unsupported logical assignments fail closed
- deterministic, durable Python automatic-command producer identity (Step 60), replacement workflow polish, and broader hardware validation remain deferred

## Related Docs

- MQTT contract: [mqtt.md](mqtt.md)
- payload fixtures: [contracts/README.md](../contracts/README.md)
- Pi deployment: [deploy/README.md](../deploy/README.md)
- Rails control plane: [ruby_service/README.md](../ruby_service/README.md)
- Python tools: [python_tools/README.md](../python_tools/README.md)
- Pico firmware: [firmware/pico_w_sensor_node/README.md](../firmware/pico_w_sensor_node/README.md)
- Pico actuator firmware: [firmware/pico_w_actuator_node/README.md](../firmware/pico_w_actuator_node/README.md)
