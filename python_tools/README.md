# Victory Garden Python Tools

Python contains the automatic watering controller, actuator daemon, shared policy logic, and simulation tools.

## Responsibilities

- Load fallback crop and zone config from YAML
- Consume live system config from Rails over MQTT
- Validate node payloads
- Track per-zone daily runtime state
- Evaluate automatic watering decisions
- Publish actuator commands and controller telemetry
- Execute zone-scoped actuator commands through the actuator daemon
- Provide a simulation tool for the MQTT contract

## Shared Contract Fixtures

The canonical node payload contract lives in:

- [`../contracts/README.md`](/Users/noel/coding/python/victory_garden/contracts/README.md)
- [`../contracts/examples/node-state-v1.json`](/Users/noel/coding/python/victory_garden/contracts/examples/node-state-v1.json)

Controller tests validate against those shared fixtures so firmware and backend stay aligned.

## Quick Start

From [`python_tools/`](/Users/noel/coding/python/victory_garden/python_tools):

- Run tests:
  - `.venv/bin/python -m pytest`
- Run the simulator:
  - `.venv/bin/python -m tools.simulate_run`
- Run the live controller loop:
  - `.venv/bin/python -m main`
- Run the actuator service:
  - `.venv/bin/python -m actuator_main`

`tools.run_loop` remains as a compatibility wrapper, but `main` is the primary production entrypoint.
`actuator_main` is the production entrypoint for the zone-scoped actuator daemon.

Both tools expect a running MQTT broker. Override the broker with `--mqtt-host` and `--mqtt-port` if needed.
Both also accept `--mqtt-username` and `--mqtt-password`, and default those from `MQTT_USERNAME` / `MQTT_PASSWORD` when present.
When available, the controller prefers retained `greenhouse/system/config/current` from Rails over local YAML so `allowed_hours`, active zones, and crop thresholds stay consistent with the UI.

## Crop Config Schema

[`config/crops.yaml`](/Users/noel/coding/python/victory_garden/python_tools/config/crops.yaml) uses:

- `crop_id`
- `crop_name`
- `dry_threshold`
- `max_pulse_runtime_sec`
- `daily_max_runtime_sec`
- `climate_preference`
- `time_to_harvest_days`

## Zone Config Schema

[`config/zones.yaml`](/Users/noel/coding/python/victory_garden/python_tools/config/zones.yaml) maps:

- `zone_id`
- `crop_id`
- `node_id`

Validation rules:

- Duplicate `crop_id` or `zone_id` is an error
- every zone must reference an existing crop profile

## MQTT Topics

The Python controller consumes and publishes:

| Topic | Purpose |
|---|---|
| `greenhouse/zones/{zone_id}/state` | node state payload with required fields and nullable optional telemetry |
| `greenhouse/system/config/current` | retained crop/zone policy broadcast from Rails |
| `greenhouse/zones/{zone_id}/command` | retained `request_reading` command |
| `greenhouse/zones/{zone_id}/actuator/command` | actuator commands published by the Python controller |
| `greenhouse/zones/{zone_id}/controller/event` | per-zone watering decision summary |
| `greenhouse/zones/{zone_id}/controller/skip` | per-zone skipped-decision summary |
| `greenhouse/zones/{zone_id}/controller/moisture_percent` | controller input moisture |
| `greenhouse/zones/{zone_id}/controller/action` | `water` or `none` |
| `greenhouse/zones/{zone_id}/controller/runtime_seconds_today` | cumulative runtime |
| `greenhouse/zones/{zone_id}/controller/skip_reason` | cooldown or duplicate-read reason |
| `greenhouse/zones/{zone_id}/actuator/status` | actuator status published by the actuator service |

## Actuator Service

The actuator daemon subscribes to `greenhouse/zones/+/actuator/command` and publishes
`greenhouse/zones/{zone_id}/actuator/status`.

Supported drivers:

- `mock`
  - default safe mode for development and packaging validation
- `shell`
  - runs `ACTUATOR_HOOK_COMMAND action zone_id runtime_seconds idempotency_key`
  - the repo now includes a Pi relay hook at `python -m tools.relay_actuator_hook`

Relevant env vars:

- `ACTUATOR_DRIVER`
- `ACTUATOR_HOOK_COMMAND`
- `ACTUATOR_GPIO_PIN`
- `ACTUATOR_GPIO_ACTIVE_LOW`
- `MQTT_HOST`
- `MQTT_PORT`
- `MQTT_USERNAME`
- `MQTT_PASSWORD`

For isolated hardware bring-up on the Pi, use:

- `.venv/bin/python -m tools.test_relay_gpio --pin 17 --active-low --cycles 5 --on-seconds 2 --off-seconds 2`

## Runtime Boundaries

- The Python controller is the authoritative automatic watering decision-maker for configured zones.
- MQTT retained node state is its working input.
- Rails/Postgres remains authoritative for crop definitions, zone claims, config publication, historical records, and manual operator actions.
- The Python actuator daemon is part of the live stack and executes `greenhouse/zones/{zone_id}/actuator/command`.
- Rails continues to schedule delayed rereads from actuator completion because that logic depends on persisted watering-event correlation.

## Notes

- The decision function remains deterministic and easy to test.
- The controller uses the canonical `greenhouse/*` topic contract.
- Incoming MQTT state is validated through `SensorReading` before any control logic touches it.
- Empty retained clears are ignored cleanly.
- The controller and actuator now emit structured JSON logs for MQTT lifecycle, decisions, skips, reread requests, command lifecycle, and driver errors.
- The current seeded thresholds are `30` for tomato and `40` for basil, reflecting current normalized sensor policy informed by crop watering preference rather than a universal absolute soil standard.
