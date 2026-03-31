# Wiring Guide

This document describes the wiring assumptions that are true in the current repo.

It is intentionally conservative:

- the Pico sensor path has concrete default pins
- the actuator path does **not** have a concrete relay GPIO hardcoded in the repo yet
- the actuator hardware wiring depends on the external driver or hook you choose

## Pico W Moisture Sensor Wiring

Current Pico defaults live in:

- [`../firmware/pico_w_sensor_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config.h)

Current moisture-read implementation lives in:

- [`../firmware/pico_w_sensor_node/src/sensors.c`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/sensors.c)

Default assumptions:

- moisture ADC GPIO: `GPIO26`
- ADC range: `0..4095`
- `moisture_percent` is derived from the ADC reading
- `moisture_invert_percent` defaults to `true`

### Basic wiring

For a simple analog moisture sensor with an analog output:

- Pico `3V3(OUT)` -> sensor `VCC`
- Pico `GND` -> sensor `GND`
- Pico `GPIO26` -> sensor analog output

Important:

- use only `3.3V`-safe sensors on the Pico ADC input
- do not drive the Pico ADC pin with `5V`
- keep grounds common

### Current software expectation

The Pico firmware currently expects:

- one analog moisture signal
- on the configured ADC GPIO
- no separate battery or temperature wiring yet

If you move the sensor output to a different ADC-capable pin, update:

- `VG_DEFAULT_MOISTURE_ADC_GPIO`

in:

- [`../firmware/pico_w_sensor_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config.h)

### Calibration note

The Pico currently does not implement dry/wet calibration in firmware.

So this wiring gets you:

- raw ADC readings
- a simple normalized `moisture_percent`

For the calibration model and current limitation, see:

- [`calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)

## Arduino MKR WiFi 1010 Moisture Wiring

The Arduino node has its own sensor assumptions in:

- [`../firmware/arduino/mkr1010_sensor_node/node_config.example.h`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/node_config.example.h)
- [`../firmware/arduino/mkr1010_sensor_node/mkr1010_sensor_node.ino`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/mkr1010_sensor_node.ino)

Important difference from Pico:

- Arduino already supports explicit `DRY_READING` and `WET_READING` calibration points

So if you want the most complete calibration path today, Arduino is the more mature node firmware.

## Actuator Wiring Status

The repo currently defines the actuator behavior at the software boundary, not at a fixed GPIO pin boundary.

Current actuator service:

- [`../python_tools/watering/actuator.py`](/Users/noel/coding/python/victory_garden/python_tools/watering/actuator.py)

Current runtime config:

- [`../deploy/victory_garden.env.example`](/Users/noel/coding/python/victory_garden/deploy/victory_garden.env.example)

Relevant settings:

- `ACTUATOR_DRIVER`
- `ACTUATOR_HOOK_COMMAND`

### What this means

The repo supports two actuator-driver shapes today:

- `mock`
- shell hook driver

With the shell hook driver:

- the Python controller publishes automatic actuator commands to MQTT
- Rails can still publish manual actuator commands from the UI
- the Python actuator service consumes them
- the actuator service runs your external hook command
- your hook command is responsible for the actual relay or pump hardware

So the relay wiring is **not** defined by a fixed pin in this repo.

### Current actuator path

Software flow:

1. the Python controller or Rails manual action publishes `greenhouse/zones/{zone_id}/actuator/command`
2. Python actuator service receives the command
3. shell hook driver runs:
   - `ACTUATOR_HOOK_COMMAND start <zone_id> <runtime_seconds> <idempotency_key>`
   - or `ACTUATOR_HOOK_COMMAND stop <zone_id> <runtime_seconds-or-empty> <idempotency_key>`
4. the hook implementation talks to your actual relay hardware
5. the actuator service publishes `greenhouse/zones/{zone_id}/actuator/status`

### Practical implication

Before writing a real relay wiring diagram, you need to decide the hardware driver shape, for example:

- Pi GPIO relay board
- USB relay
- external irrigation controller with CLI/API
- custom transistor/relay board

Until that choice is made, the actuator side should be documented as:

- a software hook contract
- not a fixed pin map

## Recommended Safe Bring-Up Order

For network and hardware stability:

1. power the Pi
2. let the Pi join Wi‑Fi and start services
3. confirm the broker and web app are up
4. power the Pico or Arduino node
5. verify live node state on MQTT before connecting any real pump or valve hardware

## Related Docs

- [`architecture.md`](/Users/noel/coding/python/victory_garden/docs/architecture.md)
- [`setup.md`](/Users/noel/coding/python/victory_garden/docs/setup.md)
- [`calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)
- [`mqtt.md`](/Users/noel/coding/python/victory_garden/docs/mqtt.md)
