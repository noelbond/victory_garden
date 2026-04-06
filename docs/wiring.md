# Wiring Guide

This document describes the wiring assumptions that are true in the current repo.

It is intentionally conservative:

- the Pico sensor path has concrete default bus pins
- the actuator path has a concrete default relay GPIO in firmware
- the final pump and relay power topology still depends on the hardware you attach

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

The actuator path is now a dedicated Pico W firmware target, separate from the sensor Pico.

Current actuator firmware:

- [`../firmware/pico_w_actuator_node/README.md`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/README.md)

Current actuator flow:

1. the Python controller or Rails manual action publishes `greenhouse/zones/{zone_id}/actuator/command`
2. the actuator Pico consumes that command
3. the actuator Pico drives its relay GPIO locally
4. the actuator Pico publishes `greenhouse/zones/{zone_id}/actuator/status`

Current hardware assumption:

- relay input -> actuator Pico `GP15`
- relay ground -> actuator Pico `GND`
- relay power -> an appropriate local supply for the relay module
- pump power remains separate from the Pico and should share ground where required by the relay interface

This keeps the outdoor relay and pump wiring local to the actuator Pico and avoids routing live relay control through the Pi.

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
