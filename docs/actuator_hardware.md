# Actuator Hardware Bring-Up

This document covers bring-up for a Pico-controlled relay, pump, or valve.

The current software boundary is already in place:

- Python controller publishes `greenhouse/zones/{zone_id}/actuator/command`
- actuator Pico consumes that command
- actuator Pico toggles the real relay
- actuator Pico publishes `greenhouse/zones/{zone_id}/actuator/status`

The goal here is to remove uncertainty before the final hardware hookup.

## Recommended Relay Interface

Use the dedicated actuator Pico as the relay driver host.

Recommended default pin selection:

- relay input pin: actuator Pico `GP15`
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

- actuator Pico `GND` must connect to relay `GND`
- actuator Pico `GND` must share ground with pump power `-`

Recommended switched path:

- pump power `+` -> relay `COM`
- relay `NO` -> pump `+`
- pump `-` -> pump power `-`
- actuator Pico `GND` -> pump power `-`
- actuator Pico `GP15` -> relay `IN`

This keeps the pump off by default and only energizes it when the relay closes `NO`.

## Isolated GPIO Test

Use the dedicated Pico relay test firmware or the actuator firmware itself with a short bounded runtime command.

Success signal:

- relay clicks on and off at a predictable cadence

Failure signals:

- no click at all
- relay stuck on
- relay logic reversed
- Pico becomes unstable or reboots

## Runtime Safety

The actuator Pico owns the runtime cutoff locally:

- relay defaults OFF on boot
- `start_watering` turns the relay on for the requested runtime
- `stop_watering` turns it off early
- runtime expiry forces OFF even if the Pi does nothing else

## Bring-Up Procedure

Step 1: Pi only

- power the Pi
- verify services are healthy
- do not connect pump power yet

Success:

- Pi boots normally
- MQTT broker and Rails services are healthy

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

- flash the dedicated actuator Pico firmware
- trigger a manual watering command from Rails or publish an actuator command directly

Success:

- the same MQTT command path toggles the relay and records actuator status

Step 6: Runtime cutoff verification

- start watering through the live actuator Pico path
- confirm the relay and pump are ON
- wait for the requested runtime to expire
- verify the relay drops OFF automatically without needing an extra command

Success:

- the pump stops when the requested runtime ends
- the system can still stop early with `stop_watering` when needed

Failure:

- relay remains ON past the requested runtime
- stop commands do not shut the relay off early

## Acceptance

This task is complete when:

- the relay toggles from the isolated GPIO test
- the live actuator Pico responds to the same MQTT actuator command path
- the real pump turns on and off without changing controller logic
