# Moisture Calibration Guide

This guide explains how Victory Garden turns a raw moisture reading into the normalized `moisture_percent` value used by crop thresholds and watering decisions.

## Current Calibration Model

The reference calibration math lives in:

- [`../python_tools/watering/calibration.py`](/Users/noel/coding/python/victory_garden/python_tools/watering/calibration.py)

Reference formula:

```text
percent = (raw_dry - raw) / (raw_dry - raw_wet) * 100
```

Then clamp to:

- `0` for anything drier than the dry reference
- `100` for anything wetter than the wet reference

Interpretation:

- `raw_dry` is the sensor value when the probe is in your dry reference condition
- `raw_wet` is the sensor value when the probe is in your wet reference condition
- values between them are linearly interpolated

For the current controller and Rails rules, `moisture_percent` is the value that matters. Crop `dry_threshold` values are policy thresholds against that normalized `0..100` scale.

## Hardware Status Today

### Arduino MKR WiFi 1010

The Arduino node already supports explicit dry/wet calibration through:

- [`../firmware/arduino/mkr1010_sensor_node/node_config.example.h`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/node_config.example.h)

Relevant fields:

- `DRY_READING`
- `WET_READING`

That firmware maps the raw reading directly to `0..100` using those two calibration points.

### Pico W

The Pico W firmware now reads the Adafruit seesaw soil sensor over I2C and supports dry/wet calibration bounds.

Current behavior in:

- [`../firmware/pico_w_sensor_node/src/sensors.c`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/sensors.c)

Current Pico behavior:

- reads moisture from seesaw `touchRead()` over I2C
- uses true dry/wet calibration when both `raw_dry` and `raw_wet` are configured
- otherwise falls back to a rough interim seesaw range

Important:

- earlier Pico ADC-based readings are not valid calibration data for the seesaw hardware
- dry/wet calibration on Pico should be restarted from scratch using seesaw readings only

## How To Capture Dry And Wet References

Use the exact probe, board, power arrangement, and wiring that you expect to run in production. Calibration values can shift if you change any of those.

### 1. Capture the dry reference

Dry means the probe is in the driest meaningful condition you want the system to treat as `0%`.

Good practice:

- keep the probe clean
- place it in dry soil, or in air if that matches the sensor’s low-end behavior better
- let the reading settle
- capture multiple samples

Record:

- board type
- probe type
- wiring
- raw reading samples
- chosen `raw_dry`

Do not use a single noisy reading. Use a small cluster and pick a stable representative value.

### 2. Capture the wet reference

Wet means the probe is in the wettest meaningful condition you want the system to treat as `100%`.

Good practice:

- place the probe in fully watered soil or the intended saturated reference condition
- let it settle
- capture multiple samples

Record:

- raw reading samples
- chosen `raw_wet`

Again, use a stable representative value rather than a single transient sample.

### 3. Sanity-check the direction

Many moisture probes behave like this:

- drier soil -> higher raw reading
- wetter soil -> lower raw reading

That is the direction assumed by the Python reference formula and by the Arduino defaults.

If your sensor is reversed:

- swap your chosen dry/wet values or adjust the mapping accordingly

## Validation Workflow

After you choose dry and wet references, validate with at least three conditions:

1. dry-ish sample
2. mid-range sample
3. wet sample

What you want:

- dry sample maps near `0..20`
- mid-range sample maps somewhere sensible in the middle
- wet sample maps near `80..100`

Then compare those numbers against your crop thresholds.

Example:

- Tomato `dry_threshold = 30`
- Basil `dry_threshold = 40`

That means your calibrated scale should make tomato watering kick in below about `30%`, and basil below about `40%`.

If the normalized percentages do not line up with real plant conditions, recalibrate the raw references before changing crop thresholds.

## Arduino Workflow

Set the calibration values in:

- [`../firmware/arduino/mkr1010_sensor_node/node_config.example.h`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/node_config.example.h)

Example:

```c
const int DRY_READING = 322;
const int WET_READING = 510;
```

Then rebuild/upload and verify the published `moisture_percent` on MQTT:

```bash
source /etc/victory_garden.env
mosquitto_sub -h localhost -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/+/state' -v
```

## Pico Workflow Today

For Pico today, focus on:

- correct seesaw I2C wiring
- stable insertion depth and probe placement
- collecting new `raw_dry` / `raw_wet` values from seesaw readings

Relevant defaults live in:

- [`../firmware/pico_w_sensor_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config.h)

Relevant fields:

- `VG_DEFAULT_SEESAW_I2C_SDA_GPIO`
- `VG_DEFAULT_SEESAW_I2C_SCL_GPIO`
- `VG_DEFAULT_SEESAW_I2C_ADDRESS`
- `VG_DEFAULT_SEESAW_TOUCH_CHANNEL`
- `VG_DEFAULT_MOISTURE_RAW_DRY`
- `VG_DEFAULT_MOISTURE_RAW_WET`

## Practical Rules

- Recalibrate if you change probe type, board, wiring, or supply behavior.
- Use the same installation geometry when collecting references as you plan to use in the garden.
- Prefer adjusting calibration first and crop thresholds second.
- Keep notes for each probe and board combination.

## Related Files

- [`../python_tools/watering/calibration.py`](/Users/noel/coding/python/victory_garden/python_tools/watering/calibration.py)
- [`../python_tools/tests/test_calibration.py`](/Users/noel/coding/python/victory_garden/python_tools/tests/test_calibration.py)
- [`../firmware/arduino/mkr1010_sensor_node/node_config.example.h`](/Users/noel/coding/python/victory_garden/firmware/arduino/mkr1010_sensor_node/node_config.example.h)
- [`../firmware/pico_w_sensor_node/src/sensors.c`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/sensors.c)
