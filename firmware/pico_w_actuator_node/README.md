# Pico W Actuator Node

Native Raspberry Pi Pico W firmware for the Victory Garden actuator node.

This firmware is the dedicated outdoor relay/pump controller. It is separate
from the sensor Pico firmware so the two boards can have distinct roles and
distinct MQTT identities.

Current scope:
- boot and serial logging
- Wi-Fi connect using Pico W native `cyw43_arch`
- lwIP MQTT client connection
- handles non-retained `start_watering` / `stop_watering` commands
- subscribes to exact per-zone command topics derived from retained actuator topology config
- publishes canonical actuator status updates
- drives one relay per configured irrigation line
- enforces a local runtime cutoff on the actuator Pico itself
- syncs UTC time over SNTP after Wi-Fi is up

Current limitations:
- no provisioning AP yet
- MQTT broker host must currently be an IPv4 address, not a hostname

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
cmake --build firmware/pico_w_sensor_node/build --target pico_w_actuator_node
```

Make sure `arm-none-eabi-gcc` is already on your `PATH` before running the build.

The build produces:
- `firmware/pico_w_sensor_node/build/pico_w_actuator_node.uf2`
- `firmware/pico_w_sensor_node/build/pico_w_actuator_node.elf`

Runtime logging:
- `pico_w_actuator_node` is configured for USB CDC logging
- use:
  - `screen /dev/cu.usbmodemXXXX 115200`
  - replacing the device path with the Pico's current USB modem path on your machine

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
- first-line relay GPIO
- relay polarity

Example:

```bash
cp firmware/pico_w_actuator_node/src/config_local.h.example \
  firmware/pico_w_actuator_node/src/config_local.h
```

Then edit `src/config_local.h` with your real Wi-Fi and broker settings.

MQTT contract:
- commands: `greenhouse/zones/{zone_id}/actuator/command`
- status: `greenhouse/zones/{zone_id}/actuator/status`
- actuator config: `greenhouse/system/actuator/config/current`

Shared actuator model:

- one irrigation line maps to one zone
- Rails publishes the installed `irrigation_line_count` and the zone-to-line assignments
- the actuator Pico subscribes to the exact zone command topics from that mapping
- each assigned zone gets its own exact command subscription after retained actuator config is applied
- the `active` field in retained actuator config is informational today; command acceptance is based on zone-to-line assignment
- line 1 uses the configured `actuator_relay_gpio`
- lines 2-12 use the default relay GPIO table in `src/config.h` unless overridden in `config_local.h`
