# Victory Garden Python Tools

Python contains the automatic watering controller, shared policy logic, and simulation tools.

## Responsibilities

- Load fallback crop and zone config from YAML
- Consume live system config from Rails over MQTT
- Validate node payloads
- Track per-zone daily runtime state
- Evaluate automatic watering decisions
- Publish actuator commands and controller telemetry
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

`tools.run_loop` remains as a compatibility wrapper, but `main` is the primary production entrypoint.

Both tools expect a running MQTT broker. Override the broker with `--mqtt-host` and `--mqtt-port` if needed.
Both also accept `--mqtt-username` and `--mqtt-password`, and default those from `MQTT_USERNAME` / `MQTT_PASSWORD` when present.
When available, the controller prefers retained `greenhouse/system/config/current` from Rails over local YAML so `allowed_hours`, active zones, and crop thresholds stay consistent with the UI.
The controller also refuses to act on stale retained readings older than `--max-reading-age-seconds` (default: 900) so an old dry payload cannot trigger watering after a long outage or restart.
For multi-sensor zones, it averages fresh readings from the zone's configured `node_ids` and can require a quorum with `--min-zone-sensor-readings` before watering.

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
| `greenhouse/zones/{zone_id}/nodes/{node_id}/state` | canonical retained node state payload with required fields and nullable optional telemetry |
| `greenhouse/zones/{zone_id}/state` | legacy retained node state payload accepted for compatibility |
| `greenhouse/system/config/current` | retained crop/zone policy broadcast from Rails |
| `greenhouse/system/actuator/config/current` | retained shared actuator topology broadcast from Rails |
| `greenhouse/zones/{zone_id}/command` | retained `request_reading` command |
| `greenhouse/zones/{zone_id}/actuator/command` | actuator commands published by the Python controller |
| `greenhouse/zones/{zone_id}/controller/event` | per-zone watering decision summary |
| `greenhouse/zones/{zone_id}/controller/skip` | per-zone skipped-decision summary |
| `greenhouse/zones/{zone_id}/controller/moisture_percent` | controller input moisture |
| `greenhouse/zones/{zone_id}/controller/action` | `water` or `none` |
| `greenhouse/zones/{zone_id}/controller/runtime_seconds_today` | cumulative runtime |
| `greenhouse/zones/{zone_id}/controller/skip_reason` | cooldown / policy / stale-reading reason |
| `greenhouse/zones/{zone_id}/actuator/status` | actuator status published by the actuator Pico |

## Actuator Commands

The Python controller publishes `greenhouse/zones/{zone_id}/actuator/command`.
The dedicated actuator Pico subscribes to that topic, enforces the bounded runtime locally, and
publishes `greenhouse/zones/{zone_id}/actuator/status`.
Rails separately publishes `greenhouse/system/actuator/config/current` so the actuator Pico knows
how many irrigation lines exist and which zone is assigned to each line.

The runtime safety boundary is on the actuator Pico:

- relay defaults OFF at boot
- `start_watering` includes a bounded `runtime_seconds`
- the actuator Pico forces relay OFF when the runtime expires
- `stop_watering` can stop the run early

## Runtime Boundaries

- The Python controller is the authoritative automatic watering decision-maker for configured zones.
- MQTT retained node state is its working input.
- Rails/Postgres remains authoritative for crop definitions, zone claims, config publication, historical records, and manual operator actions.
- The actuator Pico is part of the live stack and executes `greenhouse/zones/{zone_id}/actuator/command`.
- Shared actuator topology is configured in Rails with one irrigation line per zone.
- Rails continues to schedule delayed rereads from actuator completion because that logic depends on persisted watering-event correlation.

## Notes

- The decision function remains deterministic and easy to test.
- The controller uses the canonical `greenhouse/*` topic contract.
- Incoming MQTT state is validated through `SensorReading` before any control logic touches it.
- Empty retained clears are ignored cleanly.
- Invalid or out-of-range sensor payloads are ignored, and stale retained readings are skipped rather than watered.
- Multi-sensor zones use the average fresh moisture across configured nodes; insufficient fresh readings publish `insufficient_sensor_quorum`.
- The controller emits structured JSON logs for MQTT lifecycle, decisions, skips, reread requests, and command publication.
- The current seeded thresholds are `30` for tomato and `40` for basil, reflecting current normalized sensor policy informed by crop watering preference rather than a universal absolute soil standard.
