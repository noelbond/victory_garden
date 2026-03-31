# Victory Garden

Victory Garden is an open-source automated watering platform for small gardens and greenhouse zones. The project combines:

- Sensor node firmware for Arduino MKR WiFi 1010 and native Pico W hardware
- A Python automatic controller and zone-scoped actuator daemon
- A Rails control plane and UI for configuration, history, telemetry, and reporting

## Canonical Contract

Victory Garden uses one canonical node payload contract.

- Contract reference: [`contracts/README.md`](/Users/noel/coding/python/victory_garden/contracts/README.md)
- Shared example payloads: [`contracts/examples/`](/Users/noel/coding/python/victory_garden/contracts/examples)

The firmware, Python controller, tests, and docs should all be updated from the same contract fixtures instead of maintaining separate examples by hand.

## What Is Implemented

- Solar-friendly sensor node firmware with deep sleep and retained MQTT state
- Canonical `greenhouse/*` MQTT transport
- Crop profiles with:
  - `dry_threshold`
  - `max_pulse_runtime_sec`
  - `daily_max_runtime_sec`
  - `climate_preference`
  - `time_to_harvest_days`
- Delayed post-watering rereads requested 5 minutes after a completed watering cycle
- Daily runtime safety cap to stop the reread loop once the daily limit is met
- Optional node telemetry storage in Rails for reporting

## Repository Layout

- [`firmware/arduino/mkr1010_sensor_node/`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node)
  Sensor node firmware and local config template
- [`firmware/pico_w_sensor_node/`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node)
  Native Pico W sensor node firmware
- [`python_tools/`](/Users/noel/coding/python/victory_garden/python_tools)
  Python controller, actuator daemon, schemas, tests, and simulation tools
- [`ruby_service/`](/Users/noel/coding/python/victory_garden/ruby_service)
  Rails UI, MQTT consumer, configuration publishing, and historical reporting
- [`docs/`](/Users/noel/coding/python/victory_garden/docs)
  Architecture, MQTT contract, diagrams, and planning notes

## Canonical MQTT Topics

- `greenhouse/zones/{zone_id}/state`
  Node state payload with required control fields and optional nullable telemetry fields
- `greenhouse/zones/{zone_id}/command`
  Retained node command payload, including `request_reading`
- `greenhouse/zones/{zone_id}/command_ack`
  Node acknowledgement for handled commands
- `greenhouse/zones/{zone_id}/actuator/command`
  Actuator command payloads published by the Python controller for automatic runs and by Rails for manual actions
- `greenhouse/zones/{zone_id}/actuator/status`
  Actuator completion/fault payloads consumed by the backends
- `greenhouse/zones/{zone_id}/controller/event`
  Per-zone controller decision summaries
- `greenhouse/zones/{zone_id}/controller/skip`
  Per-zone controller skip summaries
- `greenhouse/system/config/current`
  Retained crop/zone configuration payload consumed by the Python controller

## Authority Boundaries

- PostgreSQL in Rails is the source of truth for crop profiles, zone definitions, node claims, watering history, and config sync status.
- MQTT retained node state is the live transport and working state for nodes and the Python controller, not the long-term source of truth.
- The actuator path is zone-scoped. Rails publishes to `greenhouse/zones/{zone_id}/actuator/command`, and an actuator service is expected to publish results to `greenhouse/zones/{zone_id}/actuator/status`.
- The repository now includes that actuator service in `python_tools/`.
- Python is the authoritative automatic actuator-command publisher in the deployed stack.
- Rails remains the manual actuator-command publisher, persistence layer, and config authority.
- The deployed Pi stack expects MQTT username/password auth on the local broker.
- A node's DB claim is authoritative for routing. A node's reported `zone_id` is diagnostic only.

## Implemented Crop Profiles

Current seeded/configured crops:

- Tomato
  - `dry_threshold`: `30`
  - `max_pulse_runtime_sec`: `45`
  - `daily_max_runtime_sec`: `300`
- Basil
  - `dry_threshold`: `40`
  - `max_pulse_runtime_sec`: `30`
  - `daily_max_runtime_sec`: `240`

These thresholds are calibrated policy values, not universal soil-moisture truths. They reflect the current normalized sensor model and the fact that basil should be kept wetter than tomato.
They are informed by crop care guidance, then tuned into normalized sensor percentages for this hardware.

## Reread Loop

1. The node publishes a moisture reading.
2. The Python controller decides whether to water using the latest Rails-published system config.
3. The irrigation system runs a bounded pulse.
4. After completion, Rails schedules a retained `request_reading` command 5 minutes later.
5. The node remains awake only in the immediate post-publish watch window, handles the retained request, and publishes a fresh reading.
6. The loop continues until moisture is no longer below `dry_threshold` or `daily_max_runtime_sec` is reached.

## Operational Notes

- `WateringEvent.idempotency_key` links a published watering command to its actuator status updates.
- Node commands and node config are retained where needed so sleeping nodes can consume them on the next wake cycle.
- `sensor_readings` is append-only and will grow over time. Plan a pruning or archival policy for long-running installs.

## Start Here

- Architecture overview: [`docs/architecture.md`](/Users/noel/coding/python/victory_garden/docs/architecture.md)
- Setup guide: [`docs/setup.md`](/Users/noel/coding/python/victory_garden/docs/setup.md)
- Configuration reference: [`docs/configuration.md`](/Users/noel/coding/python/victory_garden/docs/configuration.md)
- Calibration guide: [`docs/calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)
- Wiring guide: [`docs/wiring.md`](/Users/noel/coding/python/victory_garden/docs/wiring.md)
- One-zone quick start: [`docs/quickstart.md`](/Users/noel/coding/python/victory_garden/docs/quickstart.md)
- Seed data: [`docs/seed-data.md`](/Users/noel/coding/python/victory_garden/docs/seed-data.md)
- Firmware setup: [`firmware/arduino/mkr1010_sensor_node/README.md`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/README.md)
- Pico firmware setup: [`firmware/pico_w_sensor_node/README.md`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/README.md)
- Python controller: [`python_tools/README.md`](/Users/noel/coding/python/victory_garden/python_tools/README.md)
- Rails control plane: [`ruby_service/README.md`](/Users/noel/coding/python/victory_garden/ruby_service/README.md)
- Pi deployment: [`deploy/README.md`](/Users/noel/coding/python/victory_garden/deploy/README.md)

## Single-Pi Install

The Pi installer now provisions the full local stack:

- Mosquitto
- Python controller
- Python actuator service
- PostgreSQL
- Rails web app
- Rails MQTT consumer
- systemd services for each long-running process

Run on the Pi:

```bash
sudo ./deploy/install_pi.sh
```

For packaged installs, build or download one of these target release tarballs first:

- `deploy/releases/victory-garden-linux-armv7.tar.gz`
- `deploy/releases/victory-garden-linux-aarch64.tar.gz`

Each release tarball contains:

- app source
- scripts
- prebuilt Rails `vendor/bundle`
- Rails `vendor/cache`
- Python wheelhouse

The installer validates the tarball target against the Pi before it installs.

Useful runtime pages after install:

- liveness: `http://<pi-ip>:3000/up`
- operator health: `http://<pi-ip>:3000/health`
