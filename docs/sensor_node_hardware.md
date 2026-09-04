# Sensor-Node Hardware Interface Specification

## Status and scope

**Draft — NON-FROZEN.** This document records the approved range-independent
Rev A interface baseline for the Victory Garden sensor node. It is not a
schematic, BOM, PCB release, production-power design, antenna decision, or
hardware Rev A freeze. The outdoor LoRa range test remains deliberately
deferred.

The companion implementation references are:

- [`wiring.md`](wiring.md) for current bench wiring and bring-up
- [`../firmware/pico_w_sensor_node/src/config.h`](../firmware/pico_w_sensor_node/src/config.h)
  for firmware defaults
- [`lora.md`](lora.md) for the LoRa application protocol

## 1. Locked Rev A interfaces

### Controller and logic domain

- The production controller baseline is the **Raspberry Pi Pico W**.
- Firmware may continue to support Pico 2 W, but Pico 2 W is not the Rev A
  hardware baseline.
- All sensor-side digital interfaces use a **3.3 V logic domain**. No external
  device may drive a Pico GPIO at 5 V.
- Every low-voltage module and external sensor reference shares common
  low-voltage ground with the Pico.

### GPIO and bus allocation

| Function | Pico W GPIO | Physical pin | Interface connection |
| --- | ---: | ---: | --- |
| I2C1 SDA | GP14 | 19 | ADS1115 SDA and SHT40 SDA |
| I2C1 SCL | GP15 | 20 | ADS1115 SCL and SHT40 SCL |
| LR22 UART TX | GP8 | 11 | Pico TX -> LR22 RXD |
| LR22 UART RX | GP9 | 12 | Pico RX <- LR22 TXD |
| LR22 AUX | GP10 | 14 | LR22 AUX -> Pico input |
| LR22 M0 | GP4 | 6 | Pico output -> LR22 M0 |
| LR22 M1 | GP3 | 5 | Pico output -> LR22 M1 |

The LR22 control signals are populated in the Rev A interface. Their final
reset-safe electrical states remain unresolved until the selected LR22 board's
electrical behavior is confirmed.

### Sensor interface map

| Device | Locked interface |
| --- | --- |
| ADS1115 | I2C1 at address `0x48` |
| Soil channel 0 | ADS1115 `AIN0` |
| Soil channel 1 | ADS1115 `AIN1` |
| Soil channel 2 | ADS1115 `AIN2` |
| Soil channel 3 | ADS1115 `AIN3` |
| SHT40 | I2C1 at address `0x44`, shared with ADS1115 |

The four probe signals are analog inputs. Each probe's analog output must stay
within the valid ADS1115 input and common-mode range for the selected ADC
supply and measurement configuration.

## 2. Unresolved owner/component decisions

No component family, value, or part number in this table is selected by this
draft.

| Decision needed | Why it matters electrically | Information needed to choose | Downstream design affected |
| --- | --- | --- | --- |
| Exact ADS1115 module | Determines supply range, onboard pull-ups, input protection, connector layout, and analog noise behavior. | Module schematic/datasheet, supply plan, probe voltage/output range, cable environment. | I2C pull-up ownership, analog protection/filtering, rail decoupling, PCB/harness. |
| Exact SHT40 module | Determines whether `VIN` is regulated, whether level shifting/pull-ups are present, and physical mounting. | Module schematic/datasheet, operating rail, environmental/mechanical needs. | I2C pull-up ownership, rail decoupling, enclosure and harness. |
| Exact capacitive soil probe | Establishes output range, supply current, cable behavior, corrosion/lifetime, and connector needs. | Probe electrical specification, expected cable length, soil/environment exposure, calibration plan. | Analog range validation, filtering/protection, connector and cable design, calibration. |
| Exact LR22 board revision | Determines supply characteristics, UART/AUX voltage behavior, M0/M1 truth table, reset behavior, and RF connector available. | Board datasheet/schematic, electrical measurements, vendor revision identification. | M0/M1/AUX reset states, logic protection, decoupling, radio power interface, antenna integration. |
| Connector families and pinouts | Controls mating reliability, keying, IP strategy, current capacity, and accidental miswire risk. | Selected modules, enclosure, service needs, cable count/current, environmental rating. | PCB/harness, enclosure cutouts, field service and assembly. |
| Wire gauges and cable construction | Affects voltage drop, sensor noise, mechanical durability, and external-cable transient exposure. | Cable lengths, source/load current, environment, connector selection, power design. | Harness, protection, regulator budget, enclosure strain relief. |
| I2C pull resistor ownership and values | Parallel pull-ups can overload the bus; absent/incorrect rail-referenced pull-ups prevent reliable I2C. | Exact Pico/ADS1115/SHT40 board pull-up schematics, bus capacitance, cable lengths, selected rail. | Schematic, assembly options, I2C reliability. |
| Local-decoupling capacitor values and placement | Limits rail droop/noise at digital, ADC, sensor, and radio loads. | Selected modules, regulator topology, measured peak currents, layout constraints. | Schematic, PCB layout, power validation. |
| Protection component part numbers | Must match working voltage, fault energy, leakage, capacitance, and external-cable exposure. | Power source, cable topology, environmental threat model, selected connectors/modules. | Input protection, analog accuracy, ESD/surge behavior, BOM. |

Interface requirements that apply before those choices are made:

- I2C pull-up ownership must be explicitly defined after exact breakout/module
  selection.
- External probe wiring requires an explicit filtering and protection strategy.
- M0, M1, and AUX reset-safe states must be defined after confirming the exact
  LR22 electrical behavior.

## Component-selection evidence review (Step 3)

This review uses repository evidence only. It does not infer a breakout-board
design from the IC name, generic marketplace listings, or common module
conventions.

### ADS1115 module

**Not physically identified.** Repository evidence identifies an ADS1115-class
I2C ADC at `0x48`, four single-ended AINn-to-GND measurements, I2C1 at 100 kHz,
and the current firmware PGA setting of +/-4.096 V. It does not identify a
manufacturer, breakout variant, board markings, or schematic.

Consequently, the following remain unknown: module supply voltage; onboard
pull-ups and their rail; onboard decoupling; ADDR strapping; input filtering or
protection; header/connector arrangement; and whether the installed board has
any features beyond the ADC itself. `0x48` is the required current system
address, but the physical ADDR implementation has not been evidenced.

The current firmware setting does **not** prove that a probe output is safe.
Before schematic release, the selected ADC board's supply and valid
input/common-mode limits must be checked against the probe's powered output
range, including transients. A probe powered from 3.3 V may change both its
maximum analog output and its calibration; that relationship is unknown until
the probe is identified and measured.

### SHT40 module

**Not physically identified.** Repository evidence establishes only an SHT40
protocol device at `0x44` on the shared 100 kHz I2C bus. The wiring guide calls
its power pin `VIN`, which is an interface label rather than evidence of a
regulator or level shifter.

The exact breakout, supply range, pull-ups and their rail, regulator/level
shifting, decoupling, and connector/header arrangement remain unknown. They
must be established from the actual board marking, product documentation, or a
front/back board inspection.

### Soil-moisture probe

**Not physically identified.** The repository establishes four analog
capacitive probes, each with signal, local 3.3 V, and common ground wiring.
It does not state a model, supply range, output range or impedance, current
draw, cable length, wire arrangement, onboard circuitry, or recommended
filtering.

The probe output must be characterized at the intended 3.3 V supply across its
operating conditions before it can be declared safe for the ADS1115 interface.
External probe cables are an analog-noise and ESD/transient entry path; the
required filtering/protection strategy therefore remains open rather than
implicitly supplied by an unknown probe board.

### LR22 module

**Model designation identified; board revision not identified.** The bench
test records two **DX-LR22-900T22D** modules, firmware `V1.2.3`, with a
documented VCC range of 3.3–5.5 V (5 V typical in the USB-powered bench setup).
It also records 3.3 V compatibility at the Pico UART interface and observed
control behavior: AUX low means idle; AUX high means transmit, receive, or mode
change; M0/M1 low selects high-efficiency mode when hardware mode control is
enabled. The firmware drives M0 and M1 low after initialization and waits for
AUX low before sending.

This does not establish the exact PCB revision, supply-current profile, onboard
regulation/decoupling, AUX output type or reset-time state, the UART-input
limits at every intended VCC, or whether external pulls are required before the
Pico configures its GPIO. Those facts require the vendor datasheet for the
marked board revision and, where reset behavior is unspecified, a measurement
on the actual module. Antenna integration and final RF settings remain outside
this review.

### Connector interface requirements

No connector product is selected. These are the required interfaces for later
selection and schematic/harness work.

| Interface | Minimum conductors / class | Service and environment requirement |
| --- | --- | --- |
| Each soil probe | 3: 3.3 V, analog signal, ground; low-current analog | Polarized/keyed; locking desirable; outdoor-rated and strain-relieved; expected to be disconnected for probe replacement/calibration. |
| SHT40 | 4: supply, ground, SDA, SCL; low-current 3.3 V digital | Polarized/keyed; locking desirable if remotely mounted; environmental protection and strain relief required when outside the enclosure. |
| LR22 board | 7: VCC, ground, UART TX/RX, AUX, M0, M1; low-voltage digital plus radio supply current | Polarized/keyed; locking desirable; normally internal to the enclosure after assembly. The separate antenna interface is range-test-dependent. |
| Power input | At least 2: positive and return; voltage/current class unresolved | Polarized/keyed, locking, strain-relieved, and environmentally appropriate; expected service frequency is unresolved with the power-source choice. |
| Programming/service | Pico W USB and BOOTSEL access; no separate service header established | Protected from normal outdoor exposure; accessible for provisioning/recovery without disturbing field wiring. Connector selection is board-owned unless a separate service extension is later required. |

### I2C pull-up ownership finding

Neither the ADS1115 board nor the SHT40 board can be shown from repository
evidence to supply I2C pull-ups. The firmware enables the Pico GPIO internal
pull-ups, but that neither identifies their resistance nor substitutes for a
defined board-level pull-up design.

If either or both selected breakouts also provide pull-ups, their resistances
will be in parallel with each other and with the Pico's internal pulls. The
effective resistance must be calculated from the selected board schematics and
then checked for rise time and low-level sink current at the current 100 kHz
bus speed. This can matter even at 100 kHz, particularly with external cable
capacitance; no resistor value is selected by this draft.

### Evidence needed from Noel before Step 4

Provide only the following evidence for the actual parts intended for Rev A:

- ADS1115, SHT40, and soil-probe product links **or** clear front/back photos
  showing board/chip markings and every connector.
- For each probe, its cable length and a photo of the connector/wire colors;
  if no datasheet exists, measured supply voltage and output voltage in dry,
  wet, and disconnected/fault conditions.
- LR22 front/back board photos showing revision markings, plus its vendor
  datasheet/product link if available.
- A photo or wiring sketch of the intended enclosure-to-probe and
  enclosure-to-power cable entries, sufficient to establish conductor counts
  and strain-relief/environmental needs.
- Only if LR22 documentation leaves reset behavior unclear: a measured
  power-up AUX level and M0/M1 behavior before the Pico configures its GPIO.

## 3. Range-test-dependent items

The following are deliberately unresolved until the outdoor LoRa range test
and its antenna results are available:

- antenna connector and antenna type
- antenna placement, gain, orientation, and ground-plane treatment
- enclosure antenna feedthrough
- final LR22 radio profile and final transmit-power setting
- any RF-performance-driven supply filtering, decoupling, or noise changes

The existing LR22 profile is only a **bench-verified default**, not a final
field decision: 9600 baud 8-N-1, transparent mode, air-rate Level 2 / 2149
bps, 915.15 MHz / channel 41, `ff,ff` address, bandwidth 6, spreading factor
11, coding rate 1, CRC and IQ inversion enabled, and 22 dBm transmit power.

## 4. Battery-powered production operating architecture

### Product boundary

Production sensor nodes are untethered field nodes powered by a local battery
and power system. They are not a wired 5 V or 12 V distribution architecture.
USB/VBUS is limited to development, flashing, provisioning, and bench test.

The intended production communication model is **LoRa-primary**. The current
firmware is not yet that model: every cycle currently associates Wi-Fi,
attempts NTP, connects MQTT, and processes retained MQTT messages even when
LoRa transport is enabled. Production low-power operation must not require any
of those steps during a normal field cycle.

### Validated low-power feasibility boundary

The isolated `pico_w_sensor_node_lora_low_power` target physically completed
20 consecutive internal timed-sleep/wake cycles that read ADS1115 channel 0,
format the existing compact LoRa telemetry frame, and transmit it through the
LR22. The Pi raw receiver observed 20 consecutive valid frames for
`sensor-zone1-ch0`, with no malformed, duplicate, or missing frame in that
test. This is evidence for the internal ROSC-timed `WFI` feasibility path only.
It does not establish dormant current, daily energy use, long-term clock
accuracy, a production scheduler, final power hardware, or USB CDC reliability.

RP2040 RTC alarms cannot autonomously wake `xosc_dormant()` in this design.
The validated path switches clocks to ROSC, disables XOSC, waits on an internal
hardware-timer IRQ, then restores XOSC and the PLL-backed clocks. An external
dormant-capable wake source remains a fallback if later power measurements make
the internal timed-sleep path unsuitable.

### Required responsibility shift

| Current Wi-Fi/MQTT responsibility | Production LoRa-primary destination | Current gap |
| --- | --- | --- |
| Publish canonical node state | Pico sends compact LoRa telemetry; Pi gateway validates/translates it to canonical MQTT. | Autonomous LoRa telemetry and gateway translation exist. |
| Receive `request_reading` | Pi gateway queues/routes a compact LoRa command for a known sensor listen window. | Current bounded gateway retries can expire while a sleeping node is unavailable. |
| Receive node configuration | Persisted local configuration, provisioned over USB initially and later synchronized through an explicit LoRa config path. | The current LoRa command path supports only `request_reading`; no LoRa config-sync protocol exists. |
| Time synchronization | Persisted schedule/time configuration with a low-power clock, periodically corrected by the gateway during an awake window. | Current schedule depends on NTP after Wi-Fi; only a five-second internal timed-wake feasibility cycle is validated. |
| Retained-command processing | Gateway-owned command queue/state plus local command idempotency during awake windows. | Existing retained-MQTT behavior cannot run while the node is asleep/offline. |

### Intended wake/sleep cycle

The production model is conceptually:

1. Keep the controller in a validated dormant/deep-sleep state between cycles.
2. Wake from a low-power timer/clock source for the scheduled cycle.
3. Power and settle the required sensor and radio domains.
4. Read SHT40 every scheduled environmental cycle; retain the current intended
   15-minute active-window cadence unless a later scheduling decision changes
   it.
5. Read all four soil channels on the current intended hourly cadence, plus a
   valid correlated `request_reading` command.
6. Send compact LoRa telemetry to the Pi gateway.
7. Open a bounded post-wake LoRa receive window for queued commands, including
   `request_reading` and future configuration/time correction.
8. Record bounded failures, reset/recover through the watchdog as needed, and
   return every non-required load to its low-power/off state before sleep.

The current 06:00–19:59 active window, 15-minute environment cadence, and
hourly soil cadence are repository-supported. A periodic failsafe wake is also
required so a clock/configuration/command failure cannot leave the node asleep
indefinitely. The current unsynchronized fallback wakes every 15 minutes; the
final failsafe cadence is not selected here.

Nothing received over LoRa can be handled while the Pico and radio are asleep
unless a separately validated wake-on-radio design is added. Existing command
windows are 7 seconds at cycle intake, 100 ms service windows during work, and
15 seconds after telemetry; these are implementation values to measure, not a
final battery-duty-cycle allocation.

### Command availability decision

| Model | Consequences |
| --- | --- |
| **A. Scheduled awake/listen windows** | Recommended production baseline. The radio can be powered only for a wake cycle; power use, hardware behavior, and firmware state are bounded. The Pi gateway must know or learn the node wake schedule and queue/retry commands across windows. Latency is bounded by the wake interval; `request_reading` remains observational and repeat-safe. |
| **B. LR22 AUX / air-wake on demand** | Optional future capability. It may reduce command latency, but requires the radio or wake receiver to remain powered, validated AUX/air-wake electrical behavior, a Pico wake path, reset-safe states, wake authentication/retry policy, and evidence that false wakes and receive duty do not defeat the energy budget. No current repository evidence proves this behavior. |

### Power-domain strategy

| Load | Production intent | Required design/firmware consideration |
| --- | --- | --- |
| Pico W | Remains supplied by the local power system, but must enter validated dormant/deep sleep between cycles. Normal LoRa-primary cycles must not initialize Wi-Fi. | Validate wake clock and dormant current; prevent CYW43 initialization in production LoRa mode. |
| LR22 | Power only for scheduled telemetry/listen windows in the baseline model; use a documented radio low-power mode only after the exact board behavior is established. | Controller-reachable radio power-enable/load-switch control; preserve AUX, M0, and M1 routing. Continuous power is required only by a future validated air-wake model. |
| ADS1115 | Switch off between acquisition cycles unless selected-module behavior proves an equivalent low-power state. | Sensor-domain enable and startup/settling validation; protect I2C/analog pins from back-powering an unpowered board. |
| SHT40 | Switch off between environmental samples unless selected-module behavior proves an equivalent low-power state. | Sensor-domain enable and startup/settling validation; account for breakout pull-ups/back-power paths. |
| Four soil probes | Switch off between soil samples. | Provide probe-domain enable, or a separately controlled design if probe inrush/noise/calibration requires it; validate output behavior after power-up. |

This strategy implies no final GPIO allocation yet, but Rev A needs controller-
reachable, reset-safe control provision for radio power, sensor power, and
probe power. It also needs to prevent externally powered signal lines from
back-powering switched domains.

### Pico W suitability

Pico W remains a reasonable conditional baseline because the repository builds
and supports the required interfaces on it. It is not yet proven suitable for
the battery target: the internal ROSC-timed sleep path has wake/transmit
feasibility evidence but no dormant-current or complete-energy measurement.
True AON `xosc_dormant()` timed wake remains unavailable without an external
wake source. The current CYW43 architecture intentionally remains initialized
because reinitialization after deinit can hang; LoRa-primary production firmware
must avoid initializing Wi-Fi during normal operation.

Pico 2 W remains firmware-supported but has no repository power comparison.
Keep Pico W unless measurements show that validated Pico W dormant current,
wake reliability, or complete daily energy use cannot meet the selected service
interval with a practical local battery system. That result would justify a
controller reconsideration; this document does not select another MCU.

### Battery-sizing information and model

No battery chemistry, capacity, charger, or solar architecture is selected.
Battery sizing requires measured source-side current/energy for dormant sleep,
boot/wake, sensor acquisition, LR22 transmit, LR22 receive/listen, and all
regulator losses; scheduled wakes/day, command-listen duty cycle, desired
service interval, and environmental derating are also required.

Use measured source-side energy rather than nominal component current:

```text
E_day = E_dormant + N_env * E_env_wake + N_soil * E_soil_increment
        + N_command * E_command + E_fault/retry_margin

E_required = E_day * service_days * environmental/aging margin
```

Each wake term must include controller wake, enabled loads, radio TX/RX/listen,
and regulator losses. Convert `E_required` to usable battery capacity only
after the battery voltage range, allowable depth of discharge, and temperature
derating are selected.

### Required measurements

Required before battery selection:

- whole-node current/energy in the actual dormant/sleep state
- Pico-only dormant current, if practical to isolate
- sensor acquisition current and duration, including probe power-up
- LR22 idle, RX/listen, and 22 dBm transmit peak and average current
- full wake/read/transmit/listen/sleep cycle energy
- rail-voltage droop during radio transmit and controller wake

Measurements that can follow initial selection but remain required before
release: retry/fault-cycle energy, seasonal temperature effects, long-duration
clock drift, and any optional air-wake receive duty.

### Range-independent Rev A power implications

Without choosing component values, Rev A needs provision for:

- input protection and a local battery/power interface
- local decoupling and peak-current support at controller, radio, and sensor
  domains
- radio, sensor, and probe load-switch/enable control with reset-safe defaults
- battery-voltage sensing suitable for later firmware telemetry
- the existing LR22 AUX route plus a controller wake-path option if air-wake is
  later validated
- programming/service power isolation so USB/VBUS bench power does not define
  or backfeed production power behavior
- protection against back-power through I2C, UART, analog, and control lines

## 5. Power-system-dependent items

The later power-system design selects the battery chemistry/capacity, nominal
voltage range, regulator and charger topology, exact load switches, brownout
policy, and final protection ratings. It must implement the product boundary
and low-power operating requirements above without redefining locked signal
interfaces.

The documented use of Pico `VBUS` to power the LR22 is a USB-powered bench
setup only; it does not establish a production radio supply or power topology.

## Non-freeze boundary

This document locks interfaces, not component selection or final hardware
release. Hardware Rev A remains non-frozen until the range-test-dependent
radio/antenna choices and the separate power-system design are completed and
reviewed.
