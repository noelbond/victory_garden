# Victory Garden Python Tools

Python is the live watering controller and the shared functional core for the project.

## Responsibilities

- Load crop and zone config
- Validate node payloads
- Track per-zone daily runtime state
- Decide when to water based on `dry_threshold`
- Schedule retained `request_reading` commands after watering settles
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
| `greenhouse/zones/{zone_id}/command` | retained `request_reading` command |
| `greenhouse/zones/{zone_id}/controller/event` | per-zone watering decision summary |
| `greenhouse/zones/{zone_id}/controller/skip` | per-zone skipped-decision summary |
| `greenhouse/zones/{zone_id}/controller/moisture_percent` | controller input moisture |
| `greenhouse/zones/{zone_id}/controller/action` | `water` or `none` |
| `greenhouse/zones/{zone_id}/controller/runtime_seconds_today` | cumulative runtime |
| `greenhouse/zones/{zone_id}/controller/skip_reason` | cooldown or duplicate-read reason |
| `greenhouse/zones/{zone_id}/actuator/command` | actuator commands published by Rails |
| `greenhouse/zones/{zone_id}/actuator/status` | actuator status published by the actuator service |

## Actuator Service

The actuator daemon subscribes to `greenhouse/zones/+/actuator/command` and publishes
`greenhouse/zones/{zone_id}/actuator/status`.

Supported drivers:

- `mock`
  - default safe mode for development and packaging validation
- `shell`
  - runs `ACTUATOR_HOOK_COMMAND action zone_id runtime_seconds idempotency_key`

Relevant env vars:

- `ACTUATOR_DRIVER`
- `ACTUATOR_HOOK_COMMAND`
- `MQTT_HOST`
- `MQTT_PORT`

## Runtime Boundaries

- The Python controller is the live decision engine for one or more configured zones on a Pi.
- MQTT retained state is its working input, not the system-of-record for zone or node ownership.
- Rails/Postgres remains authoritative for zone definitions, node claims, and historical records.

## Delayed Reread Behavior

When the controller waters a zone:

1. it records the watering event in state
2. it waits 5 minutes for water to settle
3. it publishes a retained `request_reading` command
4. it processes the next node reading

If the zone has already reached `daily_max_runtime_sec`, the reread is not scheduled.

## Notes

- The decision function remains deterministic and easy to test.
- The controller uses the canonical `greenhouse/*` topic contract.
- Incoming MQTT state is validated through `SensorReading` before any control logic touches it.
- Empty retained clears are ignored cleanly.
- The current seeded thresholds are `30` for tomato and `40` for basil, reflecting current normalized sensor policy informed by crop watering preference rather than a universal absolute soil standard.
