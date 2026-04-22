# Victory Garden Architecture

Victory Garden is a local-first automated watering system built around MQTT, a Raspberry Pi, and microcontroller nodes for sensing and actuation.

The current deployment model is one Raspberry Pi running the broker, control plane, database, and Python controller on the same LAN as the nodes.

## Runtime Components

### Sensor nodes

Supported node implementations in this repo:

- Arduino MKR WiFi 1010 firmware
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

- consume `greenhouse/zones/{zone_id}/actuator/command`
- publish `greenhouse/zones/{zone_id}/actuator/status`
- drive the local relay output
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

- crop profiles and zone configuration
- node claiming and node config publication
- historical persistence in PostgreSQL
- MQTT ingest for node state, actuator status, and node config acknowledgements
- MQTT ingest for Python controller events so automatic watering history is persisted
- manual watering and stop commands
- delayed reread scheduling after completed watering
- operator UI, including onboarding and health pages

Important routing rule:

- `nodes.zone_id` in PostgreSQL is authoritative
- a node's reported `zone_id` is diagnostic only

### Python tools

Python fills one live role:

- automatic controller

The Python controller:

- consumes retained node state
- consumes retained `greenhouse/system/config/current` as its live crop/zone policy source
- decides when automatic watering should run
- publishes `greenhouse/zones/{zone_id}/actuator/command`
- publishes controller event and skip telemetry

Rails is no longer the automatic actuator-command publisher.

## Main Flows

### Automatic watering flow

1. A node publishes retained `node-state/v1`.
2. Rails MQTT consumer enqueues `SensorIngestJob`.
3. `SensorIngestor` normalizes the payload, updates the `Node`, and persists a `SensorReading`.
4. The Python controller consumes the same retained node state and evaluates watering policy using the latest Rails-published system config.
5. If watering is needed, Python publishes `start_watering` and emits a controller event containing the `idempotency_key`.
6. Rails ingests that controller event and persists a `WateringEvent` with status `queued`.
7. The actuator Pico runs the command and publishes status updates.
8. Rails ingests actuator status, updates the event, records faults when needed, and schedules a delayed reread after `COMPLETED`.
9. `RequestReadingJob` publishes a retained `request_reading` command back to the node.

### Manual watering flow

1. An operator triggers `Water Now` or `Stop` in Rails.
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
- claimed node-to-zone mapping
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

- a sensor node
- an actuator Pico node

The default Pi install also provisions MQTT broker authentication, shares the broker credentials with Rails and the Python services through `/etc/victory_garden.env`, and exposes `MQTT_DISCOVERY_PORT` for Pico broker rediscovery.

Useful endpoints:

- app UI: `http://<pi-ip>:3000`
- liveness: `http://<pi-ip>:3000/up`
- operator health: `http://<pi-ip>:3000/health`

## Current Project Status

- the Pico W path is integrated end to end with the live stack
- Python now owns automatic watering decisions and consumes Rails-published live config
- Rails persists automatic watering history from Python controller events and remains the manual/operator surface
- manual watering, manual stop, reboot recovery, broker restart recovery, and PostgreSQL restart recovery have all been validated on the Pi stack
- the remaining live gap is sensor reread validation with the replacement moisture sensor

## Related Docs

- MQTT contract: [`mqtt.md`](/Users/noel/coding/python/victory_garden/docs/mqtt.md)
- payload fixtures: [`../contracts/README.md`](/Users/noel/coding/python/victory_garden/contracts/README.md)
- Pi deployment: [`../deploy/README.md`](/Users/noel/coding/python/victory_garden/deploy/README.md)
- Rails control plane: [`../ruby_service/README.md`](/Users/noel/coding/python/victory_garden/ruby_service/README.md)
- Python tools: [`../python_tools/README.md`](/Users/noel/coding/python/victory_garden/python_tools/README.md)
- Pico firmware: [`../firmware/pico_w_sensor_node/README.md`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/README.md)
- Pico actuator firmware: [`../firmware/pico_w_actuator_node/README.md`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/README.md)
