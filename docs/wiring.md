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

## LoRa Sensor Node and Gateway Wiring

The current LoRa path lets the sensor Pico W send real sensor telemetry through
the Pi gateway:

1. the sensor Pico W speaks UART to a DX-LR22 radio
2. the matching DX-LR22 radio is connected to the Pi through a USB serial adapter
3. the Pi receiver service reads newline-delimited compact JSON frames
4. the receiver expands them into canonical `node-state/v1` MQTT payloads
5. the backend consumes the normal MQTT node-state topic

### Pico to DX-LR22 wiring

The bench-verified sensor Pico W wiring is:

| Pico | Physical pin | Direction | DX-LR22 |
| --- | ---: | --- | --- |
| GP8 / UART1 TX | 11 | Pico to radio | RXD |
| GP9 / UART1 RX | 12 | Radio to Pico | TXD |
| GND | 38 | Ground | GND |
| VBUS / 5 V | 40 | Power | VCC |

Optional mode/status wiring used by the current LoRa test firmware:

| Pico | Physical pin | Direction | DX-LR22 |
| --- | ---: | --- | --- |
| GP10 | 14 | Radio to Pico | AUX |
| GP4 | 6 | Pico to radio | M0 |
| GP3 | 5 | Pico to radio | M1 |

Notes:

- `GP8` is GPIO 8 / physical pin 11. It connects to the LR22 `RXD` pin because the Pico's transmit line feeds the radio's receive line.
- `GP9` is GPIO 9 / physical pin 12. It connects to the LR22 `TXD` pin because the radio's transmit line feeds the Pico's receive line.
- The LR22 power input supports 3.3-5.5 V; the verified bench setup uses Pico `VBUS` while the Pico is USB-powered.
- The LR22 UART logic is compatible with the Pico's 3.3 V GPIO. Do not drive Pico GPIO with a separate 5 V UART signal.
- Keep all grounds common.
- The same sensor Pico W also uses `GP14` / `GP15` for the ADS1115 and SHT40 I2C bus.
- The LoRa pins above do not conflict with the current sensor I2C pins.
- Enable LoRa in the sensor firmware with `VG_ENABLE_LORA_TRANSPORT true` in the local firmware config or build defines.

### Pi to DX-LR22 USB adapter

The Pi-connected radio uses the DX-LR22 USB serial adapter. The adapter maps the radio pins directly:

| DX-LR22 | USB adapter |
| --- | --- |
| VCC | VCC |
| GND | GND |
| RXD | TXD |
| TXD | RXD |
| AUX | AUX, if present |
| M0 | M0, if present |
| M1 | M1, if present |

Use a stable Linux device path from `/dev/serial/by-id/` for the receiver service. Do not use `/dev/ttyUSB0` as the saved service configuration because it can change across reboots or USB reconnects.

### Verified LR22 radio settings

Both DX-LR22-900T22D modules were verified with this shared profile:

| Setting | Value |
| --- | --- |
| UART | 9600 baud, 8-N-1 |
| Transfer mode | 0 / transparent |
| Air-rate preset | Level 2 / 2149 bps |
| Frequency/channel | 915.15 MHz / 41 |
| Address | `ff,ff` |
| Bandwidth | 6 |
| Spreading factor | 11 |
| Coding rate | 1 |
| CRC | enabled |
| IQ inversion | enabled |
| Transmit power | 22 dBm |

For the older temporary USB-to-LoRa bridge firmware, build and test notes live in:

- [`../firmware/lora_test/README.md`](../firmware/lora_test/README.md)

For the LoRa application protocol, see:

- [`lora.md`](../docs/lora.md)

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
