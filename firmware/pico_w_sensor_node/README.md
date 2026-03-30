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

Current limitations:
- no provisioning AP yet
- no battery or soil temperature driver yet
- timestamps are uptime-based placeholders until RTC/NTP is added
- MQTT broker host must currently be an IPv4 address, not a hostname
- moisture reading uses a simple ADC input on the configured GPIO

Build prerequisites:
- `arm-none-eabi-gcc`
- `cmake`
- `ninja`
- Pico SDK checked out at `firmware/pico-sdk`

Suggested environment:

```bash
export PICO_SDK_PATH=/Users/noel/coding/python/victory_garden/firmware/pico-sdk
export PATH="/Applications/ArmGNUToolchain/15.2.rel1/arm-none-eabi/bin:$PATH"
cmake -S firmware/pico_w_sensor_node -B firmware/pico_w_sensor_node/build -G Ninja -DPICO_BOARD=pico_w
cmake --build firmware/pico_w_sensor_node/build
```

The build produces:
- `firmware/pico_w_sensor_node/build/pico_w_sensor_node.uf2`
- `firmware/pico_w_sensor_node/build/pico_w_sensor_node.elf`

Runtime logging:
- `pico_w_sensor_node` is configured for USB CDC logging
- use:
  - `screen /dev/cu.usbmodem101 115200`
  - or the current Pico USB modem path if it changes
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

Default runtime values currently live in `src/config.h` and should be changed
before flashing:
- Wi-Fi SSID/password
- MQTT host/port
- node ID
- zone ID
