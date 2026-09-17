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
- sensor nodes are Pico W or Pico 2 W
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
git clone https://github.com/noelbond/victory_garden.git victory_garden
cd victory_garden
sudo ./deploy/install_pi.sh
```

For later updates from the same Git checkout:

```bash
cd /mnt/vgdata/victory_garden
git pull --ff-only
sudo ./deploy/install_pi.sh --skip-system-packages
```

See the deployment guide for the full source-checkout vs release-tarball
details:

- [`../deploy/README.md`](../deploy/README.md)

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

- [`../deploy/victory_garden.env.example`](../deploy/victory_garden.env.example)

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

For a dedicated operator log reference, see:

- [`logging.md`](../docs/logging.md)

Check web endpoints:

- app UI: `http://<pi-ip>:3000`
- liveness: `http://<pi-ip>:3000/up`
- operator health: `http://<pi-ip>:3000/health`
- setup checklist: `http://<pi-ip>:3000/onboarding`
- reading history: `http://<pi-ip>:3000/reading_history`

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

From [`../ruby_service`](../ruby_service):

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
- `http://localhost:3000/onboarding` for the `Setup Checklist`
- `http://localhost:3000/reading_history`

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

## 3. Pico Wi-Fi Firmware Setup

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
./deploy/build_firmware_bundles.sh
```

Bundled installer firmware is built with `VG_BUNDLED_BUILD=ON`, which deliberately ignores untracked `config_local.h` files. Wi-Fi and broker credentials are supplied later by the installer over USB provisioning.

Before building, make sure `arm-none-eabi-gcc` is installed and already available on your `PATH`.

Output:

- `firmware-bundles/pico_w_sensor_node.uf2`
- `firmware-bundles/pico2_w_sensor_node.uf2`
- `firmware-bundles/pico_w_actuator_node.uf2`
- `firmware-bundles/pico2_w_actuator_node.uf2`

### Flash the Pico

1. Hold `BOOTSEL`
2. Plug in the Pico you want to flash
3. Wait for:
   - `RPI-RP2` on Pico W
   - `RP2350` on Pico 2 W
4. Copy the UF2

The Pico should reboot automatically after the copy completes.

Use:

- `pico_w_sensor_node.uf2` for a Pico W sensor
- `pico2_w_sensor_node.uf2` for a Pico 2 W sensor
- `pico_w_actuator_node.uf2` for a Pico W actuator
- `pico2_w_actuator_node.uf2` for a Pico 2 W actuator

### Pico sensor runtime assumptions

Tracked defaults live in:

- [`../firmware/pico_w_sensor_node/src/config.h`](../firmware/pico_w_sensor_node/src/config.h)

Local secret and environment overrides belong in an untracked file copied from:

- [`../firmware/pico_w_sensor_node/src/config_local.h.example`](../firmware/pico_w_sensor_node/src/config_local.h.example)

Typical values to set before flashing:

- Wi‑Fi SSID/password
- MQTT broker IP/port/credentials
- NTP server

For production sensor packages, do not hand-invent the package, Zone, or
channel identities in local firmware configuration. Rails provisioning issues
them first, then the USB provisioner sends those exact values to the Pico.

Current moisture-input note:

- the Pico moisture path uses an ADS1115 I2C ADC with analog capacitive probes
- default bus settings are SDA `GPIO14` and SCL `GPIO15` on I2C1, address `0x48`
- it supports firmware dry/wet calibration using `VG_DEFAULT_CHANNEL{N}_MOISTURE_RAW_DRY` and `VG_DEFAULT_CHANNEL{N}_MOISTURE_RAW_WET`
- see [`calibration.md`](../docs/calibration.md)

### Four-channel installer flow

Rails establishes production topology before the sensor reports telemetry. One
Zone is bound to one sensor package and exactly four stable Node identities:
`{package}-ch0` through `{package}-ch3`.

1. Create the Zone in browser onboarding or call the setup API with the sensor
   package identity. Rails validates the identity, transactionally creates the
   exact four Nodes, and allocates their logical greenhouse-wide irrigation
   lines.
2. Flash the sensor Pico, then use USB provisioning. The provisioner obtains the
   backend-issued Zone ID, package ID, and four ordered channel IDs from Rails
   and sends those exact values to the Pico.
3. Verify `VG_PROVISION_OK` matches the issued package, Zone, and all four
   channel IDs. Do not continue on a mismatched acknowledgement.
4. Power the Pico and wait for telemetry only to confirm the already-known
   Nodes. Unknown telemetry is diagnostic and does not create production Nodes.
5. Give individual Nodes optional custom names, crop profiles, and logical
   irrigation-line assignments. Different Nodes in the same Zone may use
   different crops.
6. Put all four probes in dry soil and capture once. One `request_reading` wake
   publishes all four dry values.
7. Put all four probes in saturated soil and capture once. One wake publishes
   all four wet values.
8. Save dry/wet calibration independently on each channel. Rails publishes one
   aggregated config to `greenhouse/nodes/{device_id}/config` with a four-entry
   `channels` array.
9. Request a final calibrated reading and validate watering against one
   configured plant Node.

The legacy reconciliation controls are not a normal installation path. They do
not permit assigning or moving one channel independently of its package.

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

- [`../firmware/pico_w_actuator_node/src/config.h`](../firmware/pico_w_actuator_node/src/config.h)

Local secret and environment overrides belong in an untracked file copied from:

- [`../firmware/pico_w_actuator_node/src/config_local.h.example`](../firmware/pico_w_actuator_node/src/config_local.h.example)

Typical values to set before flashing:

- Wi‑Fi SSID/password
- MQTT broker IP/port/credentials
- NTP server
- actuator provisioning identity
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

- architecture: [`architecture.md`](../docs/architecture.md)
- configuration reference: [`configuration.md`](../docs/configuration.md)
- calibration guide: [`calibration.md`](../docs/calibration.md)
- wiring guide: [`wiring.md`](../docs/wiring.md)
- one-zone quick start: [`quickstart.md`](../docs/quickstart.md)
- seed data: [`seed-data.md`](../docs/seed-data.md)
- MQTT contract: [`mqtt.md`](../docs/mqtt.md)
- deployment details: [`../deploy/README.md`](../deploy/README.md)
- Rails UI and persistence layer: [`../ruby_service/README.md`](../ruby_service/README.md)
- Python tools: [`../python_tools/README.md`](../python_tools/README.md)
- Pico firmware: [`../firmware/pico_w_sensor_node/README.md`](../firmware/pico_w_sensor_node/README.md)
- Pico actuator firmware: [`../firmware/pico_w_actuator_node/README.md`](../firmware/pico_w_actuator_node/README.md)

## 5. Current Remaining Work

Hardware validation remains deferred. In particular, the final physical actuator
output capacity and real relay/sensor behavior must be validated on the target
installation; firmware builds and host tests do not establish that evidence.

Also deferred:

- deterministic, durable Python producer identity and intent persistence (Step 60)
- polished sensor replacement workflow and UI
