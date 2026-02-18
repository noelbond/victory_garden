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
- Run simulation (uses YAML config):
  - `.venv/bin/python -m tools.simulate_run`
- Run loop stub (fake readings):
  - `.venv/bin/python -m tools.run_loop`

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

## Notes

- Decision logic is pure and deterministic for easy testing.
- Hardware integration will live elsewhere (MQTT/serial/etc.).
