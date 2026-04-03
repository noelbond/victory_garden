# Pico W Sensor Node

Native Raspberry Pi Pico W firmware for the Victory Garden sensor node.

This implementation is separate from the Arduino-based firmware in
`firmware/arduino/mkr1010_sensor_node/` so both hardware options can be
supported in parallel.

Current scope:
- boot and serial logging
- persisted node config stored in flash
- Wi-Fi connect using Pico W native `cyw43_arch`
- lwIP MQTT client connection
- publishes canonical `node-state/v1` payloads
- handles retained `request_reading` commands
- handles retained `node-config/v1` payloads
- publishes `node-command-ack/v1`
- publishes `node-config-ack/v1`
- syncs UTC time over SNTP after Wi-Fi is up

Current limitations:
- no provisioning AP yet
- no battery or soil temperature driver yet
- MQTT broker host must currently be an IPv4 address, not a hostname
- the Pico moisture path now expects an Adafruit seesaw I2C soil sensor
- if `raw_dry` / `raw_wet` are not configured yet, `moisture_percent` uses a rough fallback range until calibration is completed

Build prerequisites:
- `arm-none-eabi-gcc`
- `cmake`
- `ninja`
- Pico SDK available at `firmware/pico-sdk`

If you cloned the repo without submodules, initialize the SDK first:

```bash
git submodule update --init --recursive
```

Suggested environment:

```bash
export PICO_SDK_PATH="$PWD/firmware/pico-sdk"
cmake -S firmware/pico_w_sensor_node -B firmware/pico_w_sensor_node/build -G Ninja -DPICO_BOARD=pico_w
cmake --build firmware/pico_w_sensor_node/build
```

Make sure `arm-none-eabi-gcc` is already on your `PATH` before running the build.

The build produces:
- `firmware/pico_w_sensor_node/build/pico_w_sensor_node.uf2`
- `firmware/pico_w_sensor_node/build/pico_w_sensor_node.elf`

Runtime logging:
- `pico_w_sensor_node` is configured for USB CDC logging
- use:
  - `screen /dev/cu.usbmodemXXXX 115200`
  - replacing the device path with the Pico's current USB modem path on your machine
- the separate `serial_test` target also keeps USB stdio enabled for minimal USB-only checks

Network architecture:
- the runtime target now links `pico_cyw43_arch_lwip_threadsafe_background`
- lwIP RAW API calls are bracketed with `cyw43_arch_lwip_begin/end`
- `lwipopts.h` uses a fuller Pico-compatible configuration with:
  - ARP/ICMP/UDP/TCP enabled
  - DHCP and DNS enabled
  - explicit TCP window/buffer sizing
  - larger pbuf pool and MQTT output ring buffer
  - `NO_SYS=1` for the SDK background-mode integration

Default runtime values live in `src/config.h`, but real local credentials should
go in an untracked `src/config_local.h` copied from `src/config_local.h.example`
before flashing:
- Wi-Fi SSID/password
- MQTT host/port
- NTP server
- node ID
- zone ID
- seesaw SDA/SCL pins
- seesaw I2C address / touch channel
- dry/wet calibration bounds

Example:

```bash
cp firmware/pico_w_sensor_node/src/config_local.h.example \
  firmware/pico_w_sensor_node/src/config_local.h
```

Then edit `src/config_local.h` with your real Wi-Fi and broker settings.

For the current calibration story, see:

- [`../../docs/calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)
