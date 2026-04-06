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

- [`../deploy/victory_garden.env.example`](/Users/noel/coding/python/victory_garden/deploy/victory_garden.env.example)

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
- `SOLID_QUEUE_IN_PUMA`
- `SECRET_KEY_BASE`
- `RUBY_SERVICE_DATABASE_PASSWORD`
- `RAILS_MASTER_KEY`

Use this file for:

- Rails web runtime
- Rails MQTT consumer runtime
- Python controller runtime
- local broker address, port, and credentials

## Local Rails Development

Local Rails development uses project-local Bundler wrappers instead of a repo `.env` file.

Use:

- [`../ruby_service/bin/dev-bundle`](/Users/noel/coding/python/victory_garden/ruby_service/bin/dev-bundle)
- [`../ruby_service/bin/dev-rails`](/Users/noel/coding/python/victory_garden/ruby_service/bin/dev-rails)

The local database defaults are defined in:

- [`../ruby_service/config/database.yml`](/Users/noel/coding/python/victory_garden/ruby_service/config/database.yml)

## Arduino Node Config

Arduino node local config template:

- [`../firmware/arduino/mkr1010_sensor_node/node_config.example.h`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/node_config.example.h)

Typical values to set:

- Wi‑Fi SSID/password
- MQTT broker IP/port
- node ID
- zone ID
- moisture dry/wet calibration
- publish and timeout windows
- optional battery monitor settings

This is the only node firmware in the repo that currently applies explicit dry/wet reference calibration directly in firmware.

This file is copied to:

- `firmware/arduino/mkr1010_sensor_node/node_config.h`

for a real local build.

## Pico W Node Config

Tracked defaults live in:

- [`../firmware/pico_w_sensor_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config.h)

Create an untracked local override file from:

- [`../firmware/pico_w_sensor_node/src/config_local.h.example`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config_local.h.example)

Typical values to set before flashing:

- Wi‑Fi SSID/password
- MQTT host/port/credentials
- NTP server
- node ID
- zone ID
- seesaw SDA/SCL pins
- seesaw I2C address and touch channel
- dry/wet calibration bounds once measured

Important:

- the Pico now expects a seesaw I2C moisture sensor, not a raw analog probe
- earlier ADC-based Pico readings should not be reused as calibration data
- see [`calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)

The Pico also supports persisted config in flash at runtime through retained `node-config/v1` messages from Rails.
If the Pi broker IP changes later, the Pico will fall back to UDP discovery on `MQTT_DISCOVERY_PORT`, update its saved `mqtt_host`, and reconnect automatically.

## Pico W Actuator Node Config

Tracked defaults live in:

- [`../firmware/pico_w_actuator_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/src/config.h)

Create an untracked local override file from:

- [`../firmware/pico_w_actuator_node/src/config_local.h.example`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/src/config_local.h.example)

Typical values to set before flashing:

- Wi‑Fi SSID/password
- MQTT host/port/credentials
- NTP server
- node ID
- zone ID
- relay GPIO
- relay polarity

The actuator Pico also supports persisted config in flash at runtime through retained `node-config/v1` messages from Rails.
If the Pi broker IP changes later, the actuator Pico uses the same UDP discovery fallback and persists the new `mqtt_host` before reconnecting.

## Shared MQTT Contract Fixtures

Shared example payloads live in:

- [`../contracts/examples/`](/Users/noel/coding/python/victory_garden/contracts/examples)

These are the canonical reference fixtures for:

- tests
- docs
- live debugging

The topic-level contract is documented in:

- [`mqtt.md`](/Users/noel/coding/python/victory_garden/docs/mqtt.md)

## Current Config Sources Of Truth

### Rails / Pi

Authoritative configuration is stored in PostgreSQL for:

- zones
- crop profiles
- node claims
- node config sync state

Runtime process configuration comes from:

- `/etc/victory_garden.env`

### Nodes

Node runtime behavior comes from a mix of:

- compile-time defaults
- untracked local secret overrides
- persisted local node config
- retained `node-config/v1` messages from Rails

### Broker transport

The broker itself is configured by the Pi install and local Mosquitto config files, while topic shapes and payloads are defined by:

- [`mqtt.md`](/Users/noel/coding/python/victory_garden/docs/mqtt.md)
