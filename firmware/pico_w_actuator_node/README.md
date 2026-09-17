# Pico W Actuator Node

Native Raspberry Pi Pico W firmware for the Victory Garden actuator node.

This firmware is the dedicated production relay/pump controller. One controller
serves supported Nodes across the greenhouse; it is separate from sensor Pico
firmware so the boards retain distinct roles and MQTT identities.

Current scope:
- boot and serial logging
- Wi-Fi connect using Pico W native `cyw43_arch`
- lwIP MQTT client connection
- handles non-retained `start_watering` / `stop_watering` commands
- subscribes to `greenhouse/zones/+/actuator/command`
- publishes canonical actuator status updates
- consumes retained global Node-to-line actuator topology and drives supported outputs
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
cmake -S firmware/pico_w_actuator_node -B firmware/pico_w_actuator_node/build -G Ninja -DPICO_BOARD=pico_w
cmake --build firmware/pico_w_actuator_node/build
```

Make sure `arm-none-eabi-gcc` is already on your `PATH` before running the build.

The build produces:
- `firmware/pico_w_actuator_node/build/pico_w_actuator_node.uf2`
- `firmware/pico_w_actuator_node/build/pico_w_actuator_node.elf`

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

- Rails publishes the installed `irrigation_line_count` and physically supported Node-to-line assignments
- irrigation lines are global within the greenhouse; a Zone is command, status, and journal identity metadata, not controller ownership
- a command is accepted only when its topic Zone and payload Zone match, its Node exists in retained topology, and that topology Node belongs to that Zone
- duplicate Node IDs, duplicate non-null lines, malformed assignments, and unsupported lines fail closed; an empty topology is valid for actuator-first setup
- a Node's logical assignment can remain above installed capacity. It is not remapped, but it is omitted from actuator topology and cannot water until capacity supports it
- line 1 uses the configured `actuator_relay_gpio`
- further lines use the GPIO table in `src/config.h` unless overridden in `config_local.h`; this compile-time table is not a hardware-validated final physical capacity

Safety behavior:

- START admission is durable before GPIO changes, including duplicate acknowledgement and idempotency-key conflict rejection
- command freshness, runtime guards, local runtime cutoff, targeted STOP correlation, and status correlation are enforced on-device
- journal corruption and invalid topology fail closed
- configured outputs are actively driven to their safe OFF state before the USB provisioning wait, networking, MQTT, journal work, or watchdog setup; active-high and active-low relay polarity remains supported

Hardware validation and the final physical output capacity remain deferred.
