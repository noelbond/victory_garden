# Wiring Guide

This document describes the wiring assumptions that are true in the current repo.

It is intentionally conservative:

- the Pico sensor path has concrete default bus pins
- the actuator path has a concrete default relay GPIO in firmware
- the final pump and relay power topology still depends on the hardware you attach

## Pico W Sensor Wiring

Current Pico defaults live in:

- [`../firmware/pico_w_sensor_node/src/config.h`](../firmware/pico_w_sensor_node/src/config.h)

Current moisture-read implementation lives in:

- [`../firmware/pico_w_sensor_node/src/sensors.c`](../firmware/pico_w_sensor_node/src/sensors.c)

Default assumptions:

- ADS1115 I2C SDA: `GPIO14`
- ADS1115 I2C SCL: `GPIO15`
- ADS1115 I2C address: `0x48`
- ADS1115 channels `AIN0` through `AIN3` read four analog capacitive probes
- SHT40 I2C address: `0x44`
- one Pico is one zone; each ADS1115 channel publishes as a separate node ID
- `moisture_percent` is derived from per-channel dry/wet calibration when configured, or a rough fallback range otherwise

### Basic wiring

For the ADS1115 analog probe path:

- Pico `3V3(OUT)` -> ADS1115 `VDD`
- Pico `GND` -> ADS1115 `GND`
- Pico `GPIO14` -> ADS1115 `SDA` and SHT40 `SDA`
- Pico `GPIO15` -> ADS1115 `SCL` and SHT40 `SCL`
- Pico `3V3(OUT)` -> SHT40 `VIN`
- Pico `GND` -> SHT40 `GND`
- each capacitive probe signal -> one ADS1115 input, `AIN0` through `AIN3`
- each probe power/ground -> appropriate local 3.3V/GND rails

Important:

- keep grounds common
- the ADS1115 and SHT40 share the I2C bus; the probes are analog
- calibrate each channel separately because probes and placements vary

### Current software expectation

The Pico firmware currently expects:

- one ADS1115 ADC on I2C
- one SHT40 temperature/humidity sensor on the same I2C bus
- up to four analog capacitive probes, one per ADS1115 channel
- on the configured SDA/SCL pins
- no separate battery wiring yet

If you move the sensor bus to different Pico pins, update:

- `VG_DEFAULT_ADS1115_I2C_SDA_GPIO`
- `VG_DEFAULT_ADS1115_I2C_SCL_GPIO`
- `VG_DEFAULT_ADS1115_I2C_ADDRESS`
- `VG_DEFAULT_CHANNEL{N}_NODE_ID`
- `VG_DEFAULT_CHANNEL{N}_MOISTURE_RAW_DRY`
- `VG_DEFAULT_CHANNEL{N}_MOISTURE_RAW_WET`

in:

- [`../firmware/pico_w_sensor_node/src/config.h`](../firmware/pico_w_sensor_node/src/config.h)

### Calibration note

The Pico moisture path now uses ADS1115 raw ADC counts with per-channel dry/wet bounds in firmware. Capture fresh dry/wet references for each analog probe channel.

For the calibration model and current status, see:

- [`calibration.md`](../docs/calibration.md)

## Actuator Wiring Status

The actuator path is now a dedicated Pico W firmware target, separate from the sensor Pico.

Current actuator firmware:

- [`../firmware/pico_w_actuator_node/README.md`](../firmware/pico_w_actuator_node/README.md)

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
4. power the Pico node
5. verify live node state on MQTT before connecting any real pump or valve hardware

## Related Docs

- [`architecture.md`](../docs/architecture.md)
- [`setup.md`](../docs/setup.md)
- [`calibration.md`](../docs/calibration.md)
- [`mqtt.md`](../docs/mqtt.md)
