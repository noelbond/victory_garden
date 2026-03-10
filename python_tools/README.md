# Victory Garden Python Tools

Python tooling for an open-source IoT vegetable watering system. This repo is the "functional core" for:
- Schemas (sensor readings, water commands, actuator status)
- Crop profiles (per-crop thresholds and runtimes)
- Decision logic (when to water)
- Config loading (YAML)
- State persistence (JSON)
- Simulation tools (no hardware required)

## Quick Start

From `python_tools/`:

- Run tests:
  - `.venv/bin/python -m pytest`
- Run simulation (uses YAML config, publishes to MQTT):
  - `.venv/bin/python -m tools.simulate_run`
- Run one watering-decision pass (publishes to MQTT):
  - `.venv/bin/python -m tools.run_loop`

Both tools require a running MQTT broker. Pass `--mqtt-host` and `--mqtt-port` to override the defaults (`127.0.0.1:1883`).

## Config

- `config/crops.yaml` defines crop profiles.
- `config/zones.yaml` maps zones to crops and sensor nodes.

Validation rules:
- Duplicate `crop_id` or `zone_id` is an error.
- `zones.yaml` must reference existing `crop_id` values in `crops.yaml`.

## Zone Selection (CLI)

Both the simulation and loop support selecting a zone:

- `.venv/bin/python -m tools.simulate_run --zone-id zone2`
- `.venv/bin/python -m tools.run_loop --zone-id zone1`

## Core Concepts

- `watering/schemas.py`: Pydantic models for IO (SensorReading, WaterCommand, ActuatorStatus).
- `watering/profiles.py`: CropProfile (dry threshold, runtime seconds, daily max).
- `watering/decision.py`: `decide_watering()` turns readings + profile + state into a WaterCommand.
- `watering/state.py`: ZoneState (daily runtime, last watered, last moisture).
- `watering/state_store.py`: JSON persistence for ZoneState.
- `watering/calibration.py`: Placeholder raw -> percent conversion.

## MQTT Topics

Both tools publish to the following topics:

| Topic | Content |
|---|---|
| `greenhouse/run_loop/event` | JSON summary of each decision |
| `greenhouse/simulate/event` | JSON summary of each simulation step |
| `greenhouse/zones/{zone_id}/moisture_percent` | Latest moisture reading |
| `greenhouse/zones/{zone_id}/action` | `water` or `none` |
| `greenhouse/zones/{zone_id}/runtime_seconds_today` | Cumulative runtime for the day |

## Notes

- Decision logic is pure and deterministic for easy testing.
- Real hardware (relays, sensors) publishes and subscribes to the same MQTT topics.
