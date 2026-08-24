# LoRa Wiring Test

Temporary Raspberry Pi Pico/Pico W firmware for testing a DX-LR22-compatible
LoRa module over UART1. It bridges bytes in both directions between USB serial
and the radio UART so a Mac can send payloads and query the radio with AT
commands.

At startup, the firmware probes all LR22-supported UART rates from 2400 through
115200 using read-only `+++` and `AT` commands. It keeps the detected rate for
the bridge, exits AT mode so the radio returns to transparent transmission, or
falls back to 9600 if the radio does not respond.

## Wiring

| Pico | Physical pin | Direction | DX-LR22 |
| --- | ---: | --- | --- |
| GP8 (UART1 TX) | 11 | Pico to radio | RXD |
| GP9 (UART1 RX) | 12 | Radio to Pico | TXD |
| GND | 38 | Ground | GND |
| VBUS (5 V) | 40 | Power | VCC |

The four connections above are the verified minimal wiring. `GP8` is GPIO 8,
which is physical pin 11; it is not GPIO `GP11`.

Optional hardware-mode/status wiring:

| Pico | Physical pin | Direction | DX-LR22 |
| --- | ---: | --- | --- |
| GP10 | 14 | Radio to Pico | AUX |
| GP4 | 6 | Pico to radio | M0 |
| GP3 | 5 | Pico to radio | M1 |

The verified radios use software mode control, so AUX, M0, and M1 are not
required for transparent transmission.

The DX-LR22 power input supports 3.3-5.5 V and specifies 5 V as typical. VBUS
pin 40 supplies 5 V while the Pico is USB-powered. The LR22 UART logic is
compatible with the Pico's 3.3 V GPIO; do not apply a separate 5 V UART signal
to GP8 or GP9.

## Build

From the repository root:

For a plain Pico:

```bash
cmake -S firmware/lora_test -B firmware/lora_test/build-pico -G Ninja -DPICO_BOARD=pico
cmake --build firmware/lora_test/build-pico
```

For a Pico W, use `-DPICO_BOARD=pico_w` and a separate build directory.

The plain-Pico flash image is
`firmware/lora_test/build-pico/lora_test.uf2`.

## Flash and monitor

Hold BOOTSEL while connecting the Pico, then copy `lora_test.uf2` to the
`RPI-RP2` volume. After it reboots, find and open its USB serial device:

```bash
ls /dev/cu.usbmodem*
screen /dev/cu.usbmodemXXXX 115200
```

Expected startup output:

```text
LoRa test starting...
UART1 initialized at 9600 baud
AUX = 0 (0=idle, 1=radio active)
Probing LR22 UART baud...
Returning LR22 to transparent transmission...
LR22 detected at 9600 baud
USB <-> LoRa UART bridge ready
```

For the DX-LR22, `AUX = 0` means the radio is idle and `AUX = 1` means the radio
is transmitting, receiving, or changing modes.

The test firmware drives M0 and M1 low. This selects high-efficiency mode when
the radio uses hardware mode control (`AT+SWITCH=1`). With the factory
`AT+SWITCH=0` setting, the radio also holds both pins low.

## Query the Pico-connected radio

Open the Pico USB serial port at 115200 baud. The bridge configures the LR22
UART separately at 9600 baud. Enter AT mode and query its configuration:

```text
+++
AT
AT+HELP
```

Send CR/LF after each line, including `+++`. Send `+++` again to exit AT mode
and return the radio to transparent transmission.

## Send a test packet from the Mac-connected radio

Install pyserial if needed, replace the port with the radio's actual device,
and transmit a line:

```bash
python3 - <<'PY'
import time
import serial

port = "/dev/cu.usbserial-10"
with serial.Serial(port, 9600, timeout=2) as radio:
    time.sleep(0.5)
    radio.write(b"HELLO FROM MAC\r\n")
    radio.flush()
    time.sleep(1)
PY
```

The Pico USB terminal should display `HELLO FROM MAC`. Both radios must use the
same air rate, channel, address/transmission mode, and UART baud rate.

## Verified LR22 settings

Both DX-LR22-900T22D modules were queried and verified with these settings on
2026-08-19. The complete profile was explicitly programmed into both modules
and revalidated over the Pi-to-Pico link on 2026-08-20:

| Setting | Verified value |
| --- | --- |
| Firmware | V1.2.3 |
| UART | 9600 baud, 8-N-1 |
| Transfer mode | 0 (transparent) |
| Air-rate preset | Level 2 (2149 bps) |
| Frequency/channel | 915.15 MHz / 41 |
| Address | `ff,ff` |
| Bandwidth | 6 |
| Spreading factor | 11 |
| Coding rate | 1 |
| CRC | Enabled |
| IQ inversion | Enabled |
| Transmit power | 22 dBm |

## Reliability result

The final bench test sent 100 uniquely numbered messages in each direction at
roughly 120 ms intervals:

| Direction | Sent | Unique received | Missing | Duplicates |
| --- | ---: | ---: | ---: | ---: |
| Mac to Pico | 100 | 100 | 0 | 0 |
| Pico to Mac | 100 | 100 | 0 | 0 |

This is a short-range bench result, not a range or interference test.
