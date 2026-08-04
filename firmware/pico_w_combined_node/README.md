# Pico W Combined Node

Native Raspberry Pi Pico W firmware that merges the sensor node and the
actuator node onto a single board. Use this when one Pico is wired to both
an ADS1115 (soil moisture) and a relay board, instead of running the split
`pico_w_sensor_node` / `pico_w_actuator_node` boards.

## Wiring

| Pico pin | Connects to |
| --- | --- |
| `VSYS` | Relay board `JD-VCC` / mains supply `+` |
| `GND` | Relay board `GND`, ADS1115 `GND`, supply `-` |
| `3V3` | ADS1115 `VDD` |
| `GP0` | ADS1115 `SDA` (I2C0) |
| `GP1` | ADS1115 `SCL` (I2C0) |
| `GP16` | Relay `IN1` (irrigation line 1) |
| `GP17` | Relay `IN2` (irrigation line 2) |
| `GP18` | Relay `IN3` (irrigation line 3) |
| `GP19` | Relay `IN4` (irrigation line 4) |

GP0/GP1 mux to the Pico's I2C0 hardware block (`gpio % 4`: 0/1 → I2C0, 2/3
→ I2C1), which is why `src/i2c_bus.c` initializes `i2c0` rather than `i2c1`
the way the split sensor board's `i2c1_bus.c` does with its default GP14/15
wiring. If you rewire the ADS1115 to a different pin pair, make sure it
still muxes to I2C0 (or update `i2c_bus.c`/`ads1115.c`/`sht40.c` to use
`i2c1` instead).

An SHT40 air temperature/humidity sensor can share the same I2C0 bus at
address `0x44` if wired later — it isn't required and the firmware degrades
gracefully (publishes moisture-only state) if it's absent.

## Why this exists instead of running both split firmwares

The actuator firmware keeps Wi-Fi/MQTT connected continuously so it can
receive `start_watering`/`stop_watering` in real time and enforce its local
runtime cutoff. The sensor firmware instead disconnects Wi-Fi/MQTT and puts
the Pico into deep dormant sleep between readings to save power. Those two
models can't share one Pico, so this firmware runs continuously like the
actuator does and takes soil/temperature readings on an internal timer
instead of sleeping — no deep-sleep power savings, but the board here is
powered from the relay board's supply rather than a battery, so that's an
acceptable trade.

## Node identity

Each ADS1115 channel keeps its own `node_id` (`channel_node_id[0..3]` in
config), exactly like the split sensor board. A channel's `node_id` can be
assigned to a specific relay/irrigation line via the same node-scoped
assignment mechanism the actuator already supports — a retained
`greenhouse/system/actuator/config/current` payload with a `"nodes"` array
entry like `{"node_id": "<channel node_id>", "zone_id": "...",
"irrigation_line": 1, "active": true}`. A `start_watering` command is only
honored if its `node_id` matches the channel assigned to that line, so only
the correct sensor's data path can trigger the pump it's paired with.

Current scope (superset of both split boards):
- boot and serial logging, USB provisioning (`VG_IDENTIFY`/`VG_PROVISION`,
  reports `"role":"combined"`)
- persisted node config stored in flash
- Wi-Fi connect + persistent lwIP MQTT client connection (no per-cycle
  teardown)
- publishes canonical `node-state/v1` payloads per ADS1115 channel to
  `greenhouse/zones/{zone_id}/nodes/{channel_node_id}/state`
- handles `request_reading` / `reboot` commands on `greenhouse/zones/{zone_id}/command`
- handles retained `node-config/v1` on `greenhouse/nodes/{node_id}/config`
- handles non-retained `start_watering`/`stop_watering` on
  `greenhouse/zones/{zone_id}/actuator/command`, driving one relay per
  configured irrigation line, with a local runtime cutoff enforced on-device
- subscribes to `greenhouse/system/actuator/config/current` for
  zone/node → irrigation-line assignment
- syncs UTC time over SNTP after Wi-Fi is up; soil/temperature readings are
  scheduled off synced wall-clock time the same way the split sensor board's
  wake cycle was (`VG_DAY_START_HOUR`..`VG_DAY_END_HOUR`,
  `VG_TEMP_INTERVAL_MINUTES`, `VG_SOIL_INTERVAL_MINUTES`)

Current limitations:
- no provisioning AP yet
- MQTT broker host must currently be an IPv4 address, not a hostname
- only 4 irrigation lines wired (`VG_MAX_IRRIGATION_LINES` is 4 here, vs 12
  on the standalone actuator board)

## Build

Build prerequisites:
- `arm-none-eabi-gcc`
- `cmake`
- `ninja`
- Pico SDK available at `firmware/pico-sdk`

```bash
export PICO_SDK_PATH="$PWD/firmware/pico-sdk"
cmake -S firmware/pico_w_combined_node -B firmware/pico_w_combined_node/build -G Ninja -DPICO_BOARD=pico_w
cmake --build firmware/pico_w_combined_node/build
```

The build produces:
- `firmware/pico_w_combined_node/build/pico_w_combined_node.uf2`
- `firmware/pico_w_combined_node/build/pico_w_combined_node.elf`

Default runtime values live in `src/config.h`, but real local credentials
should go in an untracked `src/config_local.h` copied from
`src/config_local.h.example` before flashing:

```bash
cp firmware/pico_w_combined_node/src/config_local.h.example \
  firmware/pico_w_combined_node/src/config_local.h
```

Then edit `src/config_local.h` with your real Wi-Fi and broker settings.

Runtime logging: this target is configured for USB CDC logging —
`screen /dev/cu.usbmodemXXXX 115200`, replacing the device path with the
Pico's current USB modem path on your machine.

Flashing/provisioning tooling (`deploy/build_firmware_bundles.sh`,
`python_tools/tools/pico_flasher_helper.py`) does not yet know about this
target — build and flash manually (BOOTSEL + drag-drop the `.uf2`, or
`picotool load`) while validating on hardware.
