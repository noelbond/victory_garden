# Actuator Hardware Bring-Up

This document covers the pre-flight bring-up for a Pi-controlled relay, pump, or valve.

The current software boundary is already in place:

- Python controller publishes `greenhouse/zones/{zone_id}/actuator/command`
- Python actuator daemon consumes that command
- actuator daemon runs a hook command
- hook command toggles the real relay
- actuator daemon publishes `greenhouse/zones/{zone_id}/actuator/status`

The goal here is to remove uncertainty before the final hardware hookup.

## Recommended Relay Interface

Use the Raspberry Pi as the relay driver host, not the Pico.

Recommended default pin selection:

- relay input pin: Pi BCM `17` (physical pin `11`)
- relay power: module `VCC`
- relay ground: module `GND`

Expected relay interface:

- `IN`
- `VCC`
- `GND`

Default trigger assumption in the repo:

- `LOW = ON`
- `HIGH = OFF`

That is common for single-channel relay modules, but it must be verified by the isolated GPIO test.

## Power Topology

Use a separate power supply for the pump or valve.

Do not power the pump directly from the Pi.

Required shared references:

- Pi `GND` must connect to relay `GND`
- Pi `GND` must share ground with pump power `-`

Recommended switched path:

- pump power `+` -> relay `COM`
- relay `NO` -> pump `+`
- pump `-` -> pump power `-`
- Pi `GND` -> pump power `-`
- Pi BCM `17` -> relay `IN`

This keeps the pump off by default and only energizes it when the relay closes `NO`.

## Isolated GPIO Test

The repo now includes a dead-simple Pi relay test:

- [`../python_tools/tools/test_relay_gpio.py`](/Users/noel/coding/python/victory_garden/python_tools/tools/test_relay_gpio.py)

It uses the same GPIO helper as the real relay hook:

- [`../python_tools/tools/relay_actuator_hook.py`](/Users/noel/coding/python/victory_garden/python_tools/tools/relay_actuator_hook.py)
- [`../python_tools/watering/relay_gpio.py`](/Users/noel/coding/python/victory_garden/python_tools/watering/relay_gpio.py)

Run on the Pi:

```bash
cd ~/victory_garden/python_tools
.venv/bin/python -m tools.test_relay_gpio --pin 17 --active-low --cycles 5 --on-seconds 2 --off-seconds 2
```

Success signal:

- relay clicks on and off at a 2-second cadence

Failure signals:

- no click at all
- relay stuck on
- relay logic reversed
- Pi becomes unstable or reboots

If the relay logic is reversed, rerun with:

```bash
.venv/bin/python -m tools.test_relay_gpio --pin 17 --no-active-low
```

## Real Actuator Hook

For the live actuator service, keep using the existing shell-hook driver and point it at the relay hook:

```bash
ACTUATOR_DRIVER=shell
ACTUATOR_HOOK_COMMAND=/home/noelbond/victory_garden/python_tools/.venv/bin/python -m tools.relay_actuator_hook
ACTUATOR_GPIO_PIN=17
ACTUATOR_GPIO_ACTIVE_LOW=true
```

That means:

- mock mode and real hardware still use the same actuator daemon code path
- only the driver implementation changes underneath it

## Bring-Up Procedure

Step 1: Pi only

- power the Pi
- verify services are healthy
- do not connect pump power yet

Success:

- Pi boots normally
- `victory-garden-actuator.service` is healthy

Step 2: Relay input test

- connect relay `VCC`, `GND`, and `IN`
- run the isolated GPIO script

Success:

- relay clicks on/off predictably

Failure:

- no click
- reversed click polarity
- unstable Pi

Step 3: External power only

- connect pump power supply to relay `COM` and pump return path
- leave the pump disconnected if you want a safer voltage-only test first

Success:

- voltage appears only on the switched side when relay is ON

Step 4: Pump ON/OFF

- connect the pump
- rerun the isolated GPIO script

Success:

- pump turns on during ON phase
- pump stops during OFF phase

Failure:

- pump always on
- pump never on
- power brownout
- relay chatter

Step 5: Full system path

- switch the actuator service from `mock` to `shell`
- use the relay hook config
- trigger a manual watering command from Rails or publish an actuator command directly

Success:

- same code path publishes command, toggles relay, and records actuator status

## Acceptance

This task is complete when:

- the relay toggles from the isolated GPIO test
- the same relay code is used by the live shell-hook actuator path
- the real pump turns on and off without changing controller logic
