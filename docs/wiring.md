# Wiring Guide

This document describes the wiring assumptions that are true in the current repo.

It is intentionally conservative:

- the Pico sensor path has concrete default bus pins
- the actuator path does **not** have a concrete relay GPIO hardcoded in the repo yet
- the actuator hardware wiring depends on the external driver or hook you choose

## Pico W Moisture Sensor Wiring

Current Pico defaults live in:

- [`../firmware/pico_w_sensor_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config.h)

Current moisture-read implementation lives in:

- [`../firmware/pico_w_sensor_node/src/sensors.c`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/sensors.c)

Default assumptions:

- seesaw I2C SDA: `GPIO4`
- seesaw I2C SCL: `GPIO5`
- seesaw I2C address: `0x36`
- seesaw touch channel: `0`
- `moisture_raw` comes from seesaw `touchRead()`
- `moisture_percent` is derived from dry/wet calibration when configured, or a rough fallback range otherwise

### Basic wiring

For the Adafruit seesaw/STEMMA soil sensor path:

- Pico `3V3(OUT)` -> sensor `VIN`
- Pico `GND` -> sensor `GND`
- Pico `GPIO4` -> sensor `SDA`
- Pico `GPIO5` -> sensor `SCL`

Important:

- keep grounds common
- the sensor is I2C, not analog
- the previous ADC-based Pico readings are not valid calibration data for this hardware

### Current software expectation

The Pico firmware currently expects:

- one seesaw moisture sensor on I2C
- on the configured SDA/SCL pins
- no separate battery wiring yet

If you move the sensor bus to different Pico pins, update:

- `VG_DEFAULT_SEESAW_I2C_SDA_GPIO`
- `VG_DEFAULT_SEESAW_I2C_SCL_GPIO`
- `VG_DEFAULT_SEESAW_I2C_ADDRESS`
- `VG_DEFAULT_SEESAW_TOUCH_CHANNEL`

in:

- [`../firmware/pico_w_sensor_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config.h)

### Calibration note

The Pico moisture path now uses the seesaw I2C sensor with calibrated dry/wet bounds in firmware. Current default calibration values are `raw_dry = 540` and `raw_wet = 820`.

For the calibration model and current status, see:

- [`calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)

## Arduino MKR WiFi 1010 Moisture Wiring

The Arduino node has its own sensor assumptions in:

- [`../firmware/arduino/mkr1010_sensor_node/node_config.example.h`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/node_config.example.h)
- [`../firmware/arduino/mkr1010_sensor_node/mkr1010_sensor_node.ino`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/mkr1010_sensor_node.ino)

Important difference from Pico:

- Arduino already supports explicit `DRY_READING` and `WET_READING` calibration points

So if you want the most complete calibration path today, Arduino is the more mature node firmware.

## Actuator Wiring Status

The repo now includes a reference Pi GPIO relay path for actuator bring-up, but the actuator behavior is still defined first at the software boundary.

Current actuator service:

- [`../python_tools/watering/actuator.py`](/Users/noel/coding/python/victory_garden/python_tools/watering/actuator.py)

Current runtime config:

- [`../deploy/victory_garden.env.example`](/Users/noel/coding/python/victory_garden/deploy/victory_garden.env.example)

Relevant settings:

- `ACTUATOR_DRIVER`
- `ACTUATOR_HOOK_COMMAND`
- `ACTUATOR_GPIO_PIN`
- `ACTUATOR_GPIO_ACTIVE_LOW`

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

The recommended default relay GPIO path is now:

- Raspberry Pi BCM `17` (physical pin `11`) -> relay `IN`
- Raspberry Pi `GND` -> relay `GND`
- Raspberry Pi power -> relay `VCC` only if the relay module is Pi-compatible

The isolated test and live hook share the same GPIO helper:

- [`../python_tools/tools/test_relay_gpio.py`](/Users/noel/coding/python/victory_garden/python_tools/tools/test_relay_gpio.py)
- [`../python_tools/tools/relay_actuator_hook.py`](/Users/noel/coding/python/victory_garden/python_tools/tools/relay_actuator_hook.py)
- [`../python_tools/watering/relay_gpio.py`](/Users/noel/coding/python/victory_garden/python_tools/watering/relay_gpio.py)

See the full bring-up guide in:

- [`actuator_hardware.md`](/Users/noel/coding/python/victory_garden/docs/actuator_hardware.md)

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
