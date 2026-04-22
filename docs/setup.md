# Victory Garden Setup Guide

This guide covers the practical setup paths that work with the current repo:

- Raspberry Pi deployment
- local Rails development
- Pico SDK and Pico W firmware build setup

It is written for the current architecture:

- Python is the automatic controller and automatic actuator-command publisher
- Rails is the UI, persistence layer, config authority, and manual-operations surface
- Mosquitto runs on the Pi
- the Python controller runs on the Pi
- sensor nodes can be Arduino MKR WiFi 1010 or Pico W
- actuation can be handled by a dedicated Pico W actuator node

## 1. Raspberry Pi Setup

### Recommended deployment shape

Use one Pi on the same LAN as the sensor nodes. The Pi runs:

- Mosquitto
- Rails web app
- Rails MQTT consumer
- PostgreSQL
- Python controller

### Install from source on the Pi

On the Pi:

```bash
git clone <your-repo-url> victory_garden
cd victory_garden
sudo ./deploy/install_pi.sh
```

### Install from a packaged release

Build or copy the correct Linux ARM tarball, then on the Pi:

```bash
tar -xzf victory-garden-linux-aarch64.tar.gz
cd victory-garden-linux-aarch64
sudo ./deploy/install_pi.sh
```

Use:

- `linux-aarch64` for 64-bit Pi OS
- `linux-armv7` for 32-bit Pi OS

### Pi config file

The installer writes:

- `/etc/victory_garden.env`

Template source:

- [`../deploy/victory_garden.env.example`](/Users/noel/coding/python/victory_garden/deploy/victory_garden.env.example)

Important values:

- `MQTT_HOST`
- `MQTT_PORT`
- `MQTT_USERNAME`
- `MQTT_PASSWORD`
- `SECRET_KEY_BASE`
- `RUBY_SERVICE_DATABASE_PASSWORD`
- `RAILS_MASTER_KEY`

### Verify the Pi stack

Check services:

```bash
sudo systemctl status greenhouse.service --no-pager
sudo systemctl status victory-garden-mqtt-discovery.service --no-pager
sudo systemctl status victory-garden-web.service --no-pager
sudo systemctl status victory-garden-mqtt-consumer.service --no-pager
sudo systemctl status mosquitto --no-pager
```

Check web endpoints:

- app UI: `http://<pi-ip>:3000`
- liveness: `http://<pi-ip>:3000/up`
- operator health: `http://<pi-ip>:3000/health`
- onboarding: `http://<pi-ip>:3000/onboarding`

Check MQTT state:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_sub -h 127.0.0.1 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/#' -v
```

### Important networking recommendation

Give the Pi a DHCP reservation in your router.

Why:

- the Pi should ideally keep a stable broker IP
- Pico nodes can rediscover the Pi automatically through the Pi's UDP discovery service if the broker address changes

Recommended startup order:

1. power the Pi
2. confirm the Pi joins Wi-Fi and services are up
3. power the Pico or other nodes

Recommended shutdown order:

1. `sudo shutdown -h now` on the Pi
2. wait for halt
3. unplug node hardware if needed

## 2. Local Rails Development Setup

The local Rails app now uses a project-local bundle instead of mixed global gems.

From [`../ruby_service`](/Users/noel/coding/python/victory_garden/ruby_service):

```bash
./bin/dev-bundle install
./bin/dev-rails db:prepare
./bin/dev-smoke
./bin/dev-rails s
```

Run tests:

```bash
./bin/dev-rails test
```

Recommended local smoke pass:

```bash
./bin/dev-smoke
```

Useful commands:

```bash
./bin/dev-rails runner 'puts RUBY_VERSION'
./bin/dev-rails test test/jobs/command_publish_job_test.rb
```

Local app pages:

- `http://localhost:3000`
- `http://localhost:3000/health`
- `http://localhost:3000/onboarding`

### Local database

The app expects a working local Postgres instance.

If needed:

```bash
brew services restart postgresql@14
createuser -s <your-macos-username>
```

Then:

```bash
cd ruby_service
./bin/dev-rails db:prepare
```

## 3. Pico W Firmware Setup

### Initialize the SDK

The repo uses the Pico SDK as a git submodule.

From the repo root:

```bash
git submodule update --init --recursive
```

### Build prerequisites

You need:

- `arm-none-eabi-gcc`
- `cmake`
- `ninja`
- Pico SDK at `firmware/pico-sdk`

Example environment:

```bash
export PICO_SDK_PATH="$PWD/firmware/pico-sdk"
cmake -S firmware/pico_w_sensor_node -B firmware/pico_w_sensor_node/build -G Ninja -DPICO_BOARD=pico_w
cmake --build firmware/pico_w_sensor_node/build --target pico_w_sensor_node pico_w_actuator_node
```

Before building, make sure `arm-none-eabi-gcc` is installed and already available on your `PATH`.

Output:

- `firmware/pico_w_sensor_node/build/pico_w_sensor_node.uf2`
- `firmware/pico_w_sensor_node/build/pico_w_actuator_node.uf2`

### Flash the Pico

1. Hold `BOOTSEL`
2. Plug in the Pico you want to flash
3. Wait for `RPI-RP2`
4. Copy the UF2

The Pico should reboot automatically after the copy completes.

Use:

- `pico_w_sensor_node.uf2` for the sensor Pico
- `pico_w_actuator_node.uf2` for the actuator Pico

### Pico sensor runtime assumptions

Tracked defaults live in:

- [`../firmware/pico_w_sensor_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config.h)

Local secret and environment overrides belong in an untracked file copied from:

- [`../firmware/pico_w_sensor_node/src/config_local.h.example`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/src/config_local.h.example)

Typical values to set before flashing:

- Wi‑Fi SSID/password
- MQTT broker IP/port/credentials
- NTP server
- node ID
- zone ID

Current moisture-input note:

- the Pico moisture path uses an Adafruit seesaw I2C soil sensor
- default bus settings are `GPIO4`/`GPIO5` on I2C address `0x36`
- it supports firmware dry/wet calibration using `VG_DEFAULT_MOISTURE_RAW_DRY` and `VG_DEFAULT_MOISTURE_RAW_WET`
- see [`calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)

### Pico verification

On the Pi:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_sub -h localhost -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/zone1/nodes/+/state' -v
```

Expected:

- retained `node-state/v1`
- real UTC timestamps
- `publish_reason` values like `interval` or `request_reading`

### Pico actuator runtime assumptions

Tracked defaults live in:

- [`../firmware/pico_w_actuator_node/src/config.h`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/src/config.h)

Local secret and environment overrides belong in an untracked file copied from:

- [`../firmware/pico_w_actuator_node/src/config_local.h.example`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/src/config_local.h.example)

Typical values to set before flashing:

- Wi‑Fi SSID/password
- MQTT broker IP/port/credentials
- NTP server
- node ID
- zone ID
- relay GPIO
- relay polarity

The actuator Pico also falls back to Pi UDP discovery if its saved broker IP becomes stale.

### Pico actuator verification

On the Pi:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_sub -h localhost -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/zone1/actuator/status' -v
```

Expected during a test run:

- `ACKNOWLEDGED`
- `RUNNING`
- `COMPLETED` or `STOPPED`

## 4. Documentation Map

- architecture: [`architecture.md`](/Users/noel/coding/python/victory_garden/docs/architecture.md)
- configuration reference: [`configuration.md`](/Users/noel/coding/python/victory_garden/docs/configuration.md)
- calibration guide: [`calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)
- wiring guide: [`wiring.md`](/Users/noel/coding/python/victory_garden/docs/wiring.md)
- one-zone quick start: [`quickstart.md`](/Users/noel/coding/python/victory_garden/docs/quickstart.md)
- seed data: [`seed-data.md`](/Users/noel/coding/python/victory_garden/docs/seed-data.md)
- MQTT contract: [`mqtt.md`](/Users/noel/coding/python/victory_garden/docs/mqtt.md)
- deployment details: [`../deploy/README.md`](/Users/noel/coding/python/victory_garden/deploy/README.md)
- Rails UI and persistence layer: [`../ruby_service/README.md`](/Users/noel/coding/python/victory_garden/ruby_service/README.md)
- Python tools: [`../python_tools/README.md`](/Users/noel/coding/python/victory_garden/python_tools/README.md)
- Pico firmware: [`../firmware/pico_w_sensor_node/README.md`](/Users/noel/coding/python/victory_garden/firmware/pico_w_sensor_node/README.md)
- Pico actuator firmware: [`../firmware/pico_w_actuator_node/README.md`](/Users/noel/coding/python/victory_garden/firmware/pico_w_actuator_node/README.md)

## 5. Current Remaining Gap

The remaining live gap is the sensor reread path on replacement hardware:

- install the replacement moisture sensor on the Pico sensor node
- recalibrate dry and wet bounds for that sensor
- rerun the full dry-soil -> water -> stop -> reread loop on hardware
