# Victory Garden

Victory Garden is an open-source automated watering platform for small gardens and greenhouse zones. The project combines:

- Arduino node firmware for MKR WiFi 1010 moisture sensor nodes
- A Python controller loop for live MQTT-driven watering decisions
- A Rails control plane and UI for configuration, history, telemetry, and reporting

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
- [`python_tools/`](/Users/noel/coding/python/victory_garden/python_tools)
  Python controller loop, schemas, config loading, tests, and simulation tools
- [`ruby_service/`](/Users/noel/coding/python/victory_garden/ruby_service)
  Rails UI, MQTT consumer, configuration publishing, and historical reporting

## Canonical MQTT Topics

- `greenhouse/zones/{zone_id}/state`
  Node state payload with required control fields and optional nullable telemetry fields
- `greenhouse/zones/{zone_id}/command`
  Retained node command payload, including `request_reading`
- `greenhouse/zones/{zone_id}/command_ack`
  Node acknowledgement for handled commands
- `greenhouse/zones/{zone_id}/actuator_status`
  Actuator completion/fault payloads consumed by the backends
- `greenhouse/irrigation/commands`
  Irrigation commands published by the control plane
- `greenhouse/config/current`
  Published crop/zone configuration payload

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
2. The controller decides whether to water.
3. The irrigation system runs a bounded pulse.
4. After completion, the backend schedules a retained `request_reading` command 5 minutes later.
5. The node remains awake only in the immediate post-publish watch window, handles the retained request, and publishes a fresh reading.
6. The loop continues until moisture is no longer below `dry_threshold` or `daily_max_runtime_sec` is reached.

## Start Here

- Firmware setup: [`firmware/arduino/mkr1010_sensor_node/README.md`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/README.md)
- Python controller: [`python_tools/README.md`](/Users/noel/coding/python/victory_garden/python_tools/README.md)
- Rails control plane: [`ruby_service/README.md`](/Users/noel/coding/python/victory_garden/ruby_service/README.md)
