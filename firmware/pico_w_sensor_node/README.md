# Pico W Sensor Node

Native Raspberry Pi Pico W firmware for the Victory Garden sensor node.

The normal Wi-Fi/MQTT target is active from 06:00 through 19:59 local time. It
publishes SHT40 air temperature and humidity every 15 minutes, samples all four
ADS1115 soil channels at minute 0 each hour, and sleeps from 20:00 until 06:00.
A manual reading request forces a fresh soil sample on the next active wake.
Without synchronized time it retries at a battery-friendly 15-minute interval.

Current scope:
- boot and serial logging
- persisted node config stored in flash
- Wi-Fi connect using Pico W native `cyw43_arch`
- lwIP MQTT client connection
- publishes canonical `node-state/v1` payloads to `greenhouse/zones/{zone_id}/nodes/{node_id}/state`
- handles retained `request_reading` commands
- handles retained `node-config/v1` payloads
- publishes `node-command-ack/v1`
- publishes `node-config-ack/v1`
- syncs UTC time over SNTP after Wi-Fi is up
- reads SHT40 temperature/humidity at I2C address `0x44`
- reads four ADS1115 soil channels at I2C address `0x48`
- optionally sends compact LoRa telemetry frames through a DX-LR22 radio when
  `VG_ENABLE_LORA_TRANSPORT` is enabled
- when LoRa is enabled, handles targeted `request_reading` commands during
  bounded awake windows and returns a correlated compact LoRa state frame

Current limitations:
- no provisioning AP yet
- no battery or soil temperature driver yet
- MQTT broker host must currently be an IPv4 address, not a hostname
- the Pico moisture path now expects one ADS1115 I2C ADC with up to four analog capacitive probes
- if `raw_dry` / `raw_wet` are not configured yet, `moisture_percent` uses a rough fallback range until calibration is completed
- LoRa telemetry is best-effort and does not use telemetry ACKs; gateway health
  is monitored from the Pi/backend side
- LoRa commands are only received while the Pico is awake; receive-while-sleeping
  requires future LR22 air wake-up work

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

## LoRa-primary low-power software baseline

`pico_w_sensor_node_lora_low_power` is an RP2040/Pico W LoRa-primary
wake-cycle software baseline for the approved battery-powered architecture.
It is excluded from the normal build; physical sleep, RF, and battery behavior
remain unvalidated. It:

- links no CYW43, lwIP, MQTT, NTP, or Wi-Fi sources;
- uses an explicit 15-minute combined sensing cadence, plus an intended
  06:00-20:00 wall-clock active window;
- treats wall clock as invalid after boot and follows the relative schedule
  until a future gateway time-sync provider is added;
- performs one bounded SHT40 read and one bounded ADS1115 read for each
  configured channel in every scheduled combined cycle;
- emits compact LoRa state only for fresh successful soil reads, attaching
  SHT40 fields only when acquired successfully in that same cycle; then
  deinitializes the UART and restores the LR22 control-safe state; and
- opens one seven-second bounded `request_reading` receive window on each
  normal wake after scheduled work (including when no state telemetry is due), preserving the
  existing channel-targeted parser, result correlation, and session dedupe;
  physical-device targets are rejected rather than treated as all-channel
  requests; and
- retains USB/GP0 phase diagnostics for bench observation only.

The receive window is intentionally shorter than a sensing interval and is not
an air-wake guarantee. It accommodates an individual gateway retry opportunity
(the gateway retries at most three times, six seconds apart), but a command
sent while the node sleeps can still miss all three attempts. No physical RF
receive behavior has been validated.

RP2040 RTC alarms do not have a dormant-wake route, so an RTC alarm cannot
wake `xosc_dormant()`. This runtime switches `clk_ref` and `clk_sys` to ROSC
and waits for an internal hardware-timer IRQ. XOSC remains enabled during that
wait so the RP2040 watchdog provides an independent reset escape if the timer
IRQ does not arrive. It restores the PLL-backed system clock and USB clock
after waking. This is not an XOSC-dormant or battery-life claim; ROSC timing is
not accurate enough to establish the production wake schedule. Clock,
scheduler, or alarm-setup failures also restore the LR22 control-safe state and
request a deterministic watchdog reset rather than spinning awake indefinitely.

The isolated target physically completed 20 consecutive wake/read/format/
transmit/sleep cycles before the scheduler skeleton was added, with the Pi raw
listener receiving 20 valid compact frames. That validates the earlier
feasibility path only; it does not validate this scheduler, power budget, final
hardware, or USB CDC reliability.

GP0 / physical pin 1 is a diagnostic phase marker. It emits 100 ms pulses with
a 300 ms gap after each group: one pulse for a timer wake, two for a successful
ADS1115 read, three for LR22/UART initialization, four immediately before the
frame is passed to the transmit function, five when that function returns
success, and six after the radio UART/control state is inactive and the cycle
is complete.
The initial boot cycle begins at phase two; use the first one-pulse group as the
start of a complete post-wake diagnostic cycle. Observe GP0 against GND with a
logic analyzer. GP8 / physical pin 11 independently shows the 9600-baud UART
bytes between the four- and five-pulse groups.

Build it explicitly for a Pico W:

```bash
cmake -S firmware/pico_w_sensor_node -B firmware/pico_w_sensor_node/build-low-power -G Ninja -DPICO_BOARD=pico_w
cmake --build firmware/pico_w_sensor_node/build-low-power --target pico_w_sensor_node_lora_low_power
```

The scheduler policy and compact LoRa protocol have Pico-SDK-free host tests:

```bash
cmake -S firmware/pico_w_sensor_node/tests -B firmware/pico_w_sensor_node/build-host-tests
cmake --build firmware/pico_w_sensor_node/build-host-tests
ctest --test-dir firmware/pico_w_sensor_node/build-host-tests --output-on-failure
```

Typical USB CDC lines at cold boot show the degraded relative schedule:

```text
[low-power] cycle=1 state=awake wall_clock_valid=false active=true combined_due=true
[low-power] cycle=1 environment attempted=true success=true
[low-power] cycle=1 soil channel=0 attempted=true success=true
[low-power] cycle=1 command-window=open duration_ms=7000
[low-power] cycle=1 state=rosc-sleep-armed wake_in_ms=900000
```

The three-second USB startup delay, USB logging, and GP0 phase pulses are
feasibility diagnostics. They are not production requirements and must not be
used for battery-life claims. USB CDC may drop across repeated clock
transitions.

The normal `pico_w_sensor_node` target remains the known-good Wi-Fi/MQTT path.

Runtime logging:
- `pico_w_sensor_node` is configured for USB CDC logging
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
- zone ID
- ADS1115 SDA/SCL pins
- ADS1115 I2C address
- per-channel node IDs and dry/wet calibration bounds
- `VG_ENABLE_LORA_TRANSPORT true` plus LoRa UART/control pins if this sensor
  node should transmit over LoRa

Example:

```bash
cp firmware/pico_w_sensor_node/src/config_local.h.example \
  firmware/pico_w_sensor_node/src/config_local.h
```

Then edit `src/config_local.h` with your real Wi-Fi and broker settings.

For the current calibration story, see:

- [`../../docs/calibration.md`](../../docs/calibration.md)

## Optional LoRa Telemetry

When `VG_ENABLE_LORA_TRANSPORT` is enabled, the sensor Pico W sends one compact
LoRa state frame per ADS1115 channel whenever soil readings are taken. The Pi
gateway expands those compact frames into canonical `node-state/v1` MQTT
payloads.

Bench-validated LoRa pin defaults:

| Pico W | DX-LR22 |
| --- | --- |
| `GP8` / UART1 TX / physical pin 11 | `RXD` |
| `GP9` / UART1 RX / physical pin 12 | `TXD` |
| `GP10` / physical pin 14 | `AUX` |
| `GP4` / physical pin 6 | `M0` |
| `GP3` / physical pin 5 | `M1` |
| `VBUS` / physical pin 40 (USB-powered bench only) | `VCC` |
| `GND` / physical pin 38 | `GND` |

`VBUS` is not the production radio-power interface. The approved production
architecture supplies the LR22 from the still-to-be-finalized local battery
power system.

The LoRa path preserves the normal firmware rhythm:

1. boot/wake
2. connect Wi-Fi and MQTT
3. poll LoRa briefly for targeted commands during bounded awake windows
4. read SHT40 and ADS1115 sensors
5. publish canonical MQTT state
6. send best-effort compact LoRa state frames unless a LoRa command response was
   already sent in the same cycle
7. sleep until the next scheduled wake

Failure behavior:

- all local LoRa sends use bounded AUX and UART-write waits; the LoRa-primary
  runtime also uses a bounded UART-drain wait before radio teardown
- after one local LoRa send failure, the node skips remaining LoRa sends for
  that wake cycle
- MQTT publishing and sleep continue
- without telemetry ACKs, the Pico cannot detect that the Pi gateway did not
  hear an otherwise successful LR22 UART send
- a valid targeted LoRa `request_reading` command returns one compact
  state/result frame with the original command `message_id`
- duplicate copies of the same LoRa command are suppressed while pending and
  while retained in the eight-entry completed-command cache during the current
  Pico boot/session; the cache is in memory, does not survive reboot, can evict
  older completions, and does not replay a prior result when it suppresses a
  duplicate
- the compact command has no timestamp/age field and firmware has no
  stale-command age rejection, so a delayed `request_reading` may execute after
  the server-side command timeout; this is acceptable only because it is
  observational and repeat-safe

LoRa `request_reading` is not an actuator-command reliability mechanism. A
future side-effecting LoRa command needs durable cross-reboot idempotency,
completion correlation, a freshness policy, and fail-safe handling of
ambiguous retries before it can use this path.

For the current bench wiring and non-frozen hardware interface baseline, see:

- [`../../docs/wiring.md`](../../docs/wiring.md#lora-sensor-node-and-gateway-wiring)
- [`../../docs/sensor_node_hardware.md`](../../docs/sensor_node_hardware.md)

For the compact LoRa frame contract, see:

- [`../../docs/lora.md`](../../docs/lora.md)
