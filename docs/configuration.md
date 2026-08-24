# Victory Garden Configuration Reference

This document points to the configuration files and example templates that matter in the current repo.

## Pi Runtime Environment

The main Pi runtime environment file is:

- `/etc/victory_garden.env`

It is installed root-readable, so when you need broker credentials in a regular shell use:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
```

Template source in the repo:

- [`../deploy/victory_garden.env.example`](../deploy/victory_garden.env.example)

Current keys:

- `RAILS_ENV`
- `RAILS_LOG_LEVEL`
- `RAILS_SERVE_STATIC_FILES`
- `RAILS_FORCE_SSL`
- `RAILS_ASSUME_SSL`
- `APP_HOST`
- `PORT`
- `MQTT_HOST`
- `MQTT_PORT`
- `MQTT_DISCOVERY_PORT`
- `MQTT_USERNAME`
- `MQTT_PASSWORD`
- `LORA_SERIAL_PORT`
- `LORA_BAUDRATE`
- `LORA_SERIAL_TIMEOUT_SECONDS`
- `LORA_READ_SIZE`
- `LORA_RECONNECT_DELAY_SECONDS`
- `LORA_MAX_FRAME_SIZE`
- `LORA_DEDUP_RECENT_FRAMES`
- `LORA_COMMAND_MAX_ATTEMPTS`
- `LORA_COMMAND_RETRY_DELAY_SECONDS`
- `SOLID_QUEUE_IN_PUMA`
- `SECRET_KEY_BASE`
- `RUBY_SERVICE_DATABASE_PASSWORD`
- `RAILS_MASTER_KEY`

Use this file for:

- Rails web runtime
- Rails MQTT consumer runtime
- Python controller runtime
- LoRa receiver runtime
- local broker address, port, and credentials

### LoRa receiver environment

The LoRa receiver service is:

- `victory-garden-lora-receiver.service`

It reads:

| Key | Default | Purpose |
| --- | --- | --- |
| `LORA_SERIAL_PORT` | `/dev/serial/by-id/REPLACE_WITH_LORA_ADAPTER` | Stable USB serial path for the Pi-connected LR22 adapter |
| `LORA_BAUDRATE` | `9600` | LR22 UART baud rate |
| `LORA_SERIAL_TIMEOUT_SECONDS` | `1.0` | Serial read timeout used by the receiver loop |
| `LORA_READ_SIZE` | `256` | Maximum bytes read from serial per read call |
| `LORA_RECONNECT_DELAY_SECONDS` | `2.0` | Delay before retrying after USB serial disconnect/error |
| `LORA_MAX_FRAME_SIZE` | `1024` | Maximum accepted newline-delimited frame size |
| `LORA_DEDUP_RECENT_FRAMES` | `32` | Recent exact frames remembered for duplicate suppression |
| `LORA_COMMAND_MAX_ATTEMPTS` | `3` | Total transmit attempts for a correlated LoRa `request_reading` command, including the first send |
| `LORA_COMMAND_RETRY_DELAY_SECONDS` | `6.0` | Delay before retrying a LoRa command that has not produced a correlated published state result |

`LORA_SERIAL_PORT` should be a `/dev/serial/by-id/...` path. Do not save `/dev/ttyUSB0` or `/dev/ttyACM0` in production config because those names can change after reboot or reconnect.

The receiver also uses the shared MQTT keys:

- `MQTT_HOST`
- `MQTT_PORT`
- `MQTT_USERNAME`
- `MQTT_PASSWORD`

It publishes validated inbound LoRa state frames to canonical MQTT
`node-state/v1` topics with QoS 1 and retained delivery. It also subscribes to
`greenhouse/nodes/+/lora/command` and routes valid `lora-command/v1` command
payloads to newline-delimited compact LoRa command frames on the Pi-connected
LR22 serial stream while the serial connection is live.

For the LoRa application protocol, see:

- [`lora.md`](../docs/lora.md)

## Local Rails Development

Local Rails development uses project-local Bundler wrappers instead of a repo `.env` file.

Use:

- [`../ruby_service/bin/dev-bundle`](../ruby_service/bin/dev-bundle)
- [`../ruby_service/bin/dev-rails`](../ruby_service/bin/dev-rails)

The local database defaults are defined in:

- [`../ruby_service/config/database.yml`](../ruby_service/config/database.yml)

## Pico W Node Config

Tracked defaults live in:

- [`../firmware/pico_w_sensor_node/src/config.h`](../firmware/pico_w_sensor_node/src/config.h)

Create an untracked local override file from:

- [`../firmware/pico_w_sensor_node/src/config_local.h.example`](../firmware/pico_w_sensor_node/src/config_local.h.example)

Typical values to set before flashing:

- Wi‑Fi SSID/password
- MQTT host/port/credentials
- NTP server
- node ID
- zone ID
- ADS1115 SDA/SCL pins
- ADS1115 I2C address
- per-channel node IDs and dry/wet calibration bounds once measured

Important:

- the Pico now expects an ADS1115 I2C ADC reading analog capacitive probes
- earlier readings from different sensor hardware should not be reused as calibration data
- see [`calibration.md`](../docs/calibration.md)

The Pico also supports persisted config in flash at runtime through retained `node-config/v1` messages from Rails.
If the Pi broker IP changes later, the Pico will fall back to UDP discovery on `MQTT_DISCOVERY_PORT`, update its saved `mqtt_host`, and reconnect automatically.

## Pico W Actuator Node Config

Tracked defaults live in:

- [`../firmware/pico_w_actuator_node/src/config.h`](../firmware/pico_w_actuator_node/src/config.h)

Create an untracked local override file from:

- [`../firmware/pico_w_actuator_node/src/config_local.h.example`](../firmware/pico_w_actuator_node/src/config_local.h.example)

Typical values to set before flashing:

- Wi‑Fi SSID/password
- MQTT host/port/credentials
- NTP server
- node ID
- zone ID
- relay GPIO
- relay polarity

Rails publishes retained shared actuator topology on `greenhouse/system/actuator/config/current`,
including `irrigation_line_count` and the zone-to-line assignments. If the Pi broker IP changes later,
the actuator Pico uses the same UDP discovery fallback and persists the new `mqtt_host` before reconnecting.

The retained actuator topology is also what drives exact MQTT command subscriptions on the actuator Pico.
Today the Pico uses the `zone_id` to `irrigation_line` assignment from that payload directly; the `active`
field is published for shared topology visibility but is not yet enforced as a device-side command gate.

## Shared MQTT Contract Fixtures

Shared example payloads live in:

- [`../contracts/examples/`](../contracts/examples)

These are the canonical reference fixtures for:

- tests
- docs
- contract validation

The topic-level contract is documented in:

- [`mqtt.md`](../docs/mqtt.md)

## Current Config Sources Of Truth

### Rails / Pi

Authoritative configuration is stored in PostgreSQL for:

- zones
- crop profiles
- node assignments
- node config sync state

Runtime process configuration comes from:

- `/etc/victory_garden.env`

### Nodes

Node runtime behavior comes from a mix of:

- compile-time defaults
- untracked local secret overrides
- persisted local node config
- retained `node-config/v1` messages from Rails

For the actuator Pico specifically, live topology comes from retained
`greenhouse/system/actuator/config/current` rather than `node-config/v1`.

### Broker transport

The broker itself is configured by the Pi install and local Mosquitto config files, while topic shapes and payloads are defined by:

- [`mqtt.md`](../docs/mqtt.md)
