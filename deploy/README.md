# Pi Deployment

## Release Tarballs

Build target-specific release tarballs on matching Linux ARM hardware:

```bash
./deploy/build_release.sh --target linux-armv7
./deploy/build_release.sh --target linux-aarch64
```

Each tarball contains:

- app source
- deploy scripts
- `python_wheelhouse/`
- `ruby_service/vendor/bundle/`
- `ruby_service/vendor/cache/`
- `deploy/release_manifest.json`

Release builds are now strict about firmware too:

- `deploy/build_release.sh` builds bundled UF2s for Pico W and Pico 2 W sensor/actuator boards before writing the release manifest
- the build host must have `cmake`, `ninja`, and the ARM embedded toolchain (`arm-none-eabi-gcc`, `arm-none-eabi-g++`, `arm-none-eabi-objcopy`, `arm-none-eabi-objdump`)
- `deploy/install_pi.sh` rejects a release tarball whose manifest does not show a successful firmware verification step

Output:

- `deploy/releases/victory-garden-linux-armv7.tar.gz`
- `deploy/releases/victory-garden-linux-aarch64.tar.gz`

Build these artifacts on a matching Linux ARM host. Do not build them on macOS.

## Install From A Release Tarball

On the Pi:

1. Download or copy the correct target tarball.
2. Extract it.
3. Run:

```bash
cd victory-garden-linux-aarch64
sudo ./deploy/install_pi.sh
```

or:

```bash
cd victory-garden-linux-armv7
sudo ./deploy/install_pi.sh
```

The installer verifies that the Pi matches the packaged target before it continues.

Release installs are strict:

- packaged `ruby_service/vendor/bundle/` must already be complete for the target Pi
- packaged `python_wheelhouse/` is expected for fast Python setup
- if the packaged Rails bundle is incomplete, the installer fails instead of rebuilding gems on the user's Pi

That keeps first-time user installs deterministic and pushes native Ruby bundling back into the release-build step.

## Install From Source

For a single-Pi source install:

1. Clone this repository onto the Pi.
2. Run:

```bash
git clone https://github.com/noelbond/victory_garden.git victory_garden
cd victory_garden
sudo ./deploy/install_pi.sh
```

The script will:

- install system packages for Python, Ruby, PostgreSQL, and Mosquitto
- create `python_tools/.venv` on the Pi
- install the Python controller runtime dependencies
- reuse packaged `python_wheelhouse/` if present
- reuse packaged `ruby_service/vendor/bundle/` if present
- fall back to local `vendor/cache` or internet installs when needed
- create the production PostgreSQL role and databases
- run `db:prepare` and `db:seed`
- install or update systemd units for `greenhouse.service`, `victory-garden-mqtt-discovery.service`, `victory-garden-web.service`, `victory-garden-mqtt-consumer.service`, and `victory-garden-lora-receiver.service`
- restart the full stack

For routine updates after the first install, keep the runtime tree as a Git
checkout and run:

```bash
cd /mnt/vgdata/victory_garden
git pull --ff-only
sudo ./deploy/install_pi.sh --skip-system-packages
```

`git pull` only updates source files. The installer is still required after a
pull because it applies environment defaults, dependencies, database
preparation, systemd units, and service restarts.

Source-checkout installs should not keep release-only packaging artifacts in
the active runtime tree:

- `deploy/release_manifest.json`
- `python_wheelhouse/`

Those files are expected in release tarballs. In a live Git checkout,
`deploy/release_manifest.json` makes the installer treat the tree like a
packaged release.

Generated config:

- app env file: `/etc/victory_garden.env`
- example env template: [`victory_garden.env.example`](../deploy/victory_garden.env.example)

Web endpoints after install:

- app: `http://<pi-ip>:3000`
- liveness: `http://<pi-ip>:3000/up`
- operator health: `http://<pi-ip>:3000/health`
- setup checklist: `http://<pi-ip>:3000/onboarding`
- reading history: `http://<pi-ip>:3000/reading_history`

Verify after install:

```bash
sudo systemctl status greenhouse.service --no-pager
sudo systemctl status victory-garden-mqtt-discovery.service --no-pager
sudo systemctl status victory-garden-web.service --no-pager
sudo systemctl status victory-garden-mqtt-consumer.service --no-pager
sudo systemctl status victory-garden-lora-receiver.service --no-pager
sudo journalctl -u greenhouse.service -n 50 --no-pager
sudo journalctl -u victory-garden-mqtt-discovery.service -n 50 --no-pager
sudo journalctl -u victory-garden-web.service -n 50 --no-pager
sudo journalctl -u victory-garden-mqtt-consumer.service -n 50 --no-pager
sudo journalctl -u victory-garden-lora-receiver.service -n 50 --no-pager
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_sub -h 127.0.0.1 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/+/nodes/+/state' -v
```

The Pi install also starts `victory-garden-mqtt-discovery.service`, a small UDP responder that returns the Pi's current broker IP and MQTT port so Pico nodes can recover automatically if the Pi's LAN IP changes.

LoRa receiver serial path:

- Use a stable USB path from `/dev/serial/by-id/`, not `/dev/ttyUSB0` or `/dev/ttyACM0`.
- Set `LORA_ENABLED=true` in `/etc/victory_garden.env` on a Pi that should run
  as a LoRa gateway. Leave it `false` for Wi-Fi-only installs.
- The installer writes `LORA_SERIAL_PORT` to `/etc/victory_garden.env`. If exactly one USB serial adapter is present during install, it uses that `/dev/serial/by-id/...` path automatically.
- If the adapter was not present, or more than one USB serial adapter was present, set it manually:

```bash
ls -l /dev/serial/by-id/
sudoedit /etc/victory_garden.env
sudo ./deploy/install_pi.sh --skip-system-packages
sudo systemctl restart victory-garden-lora-receiver.service
```

Set `LORA_SERIAL_PORT=/dev/serial/by-id/<your-lora-usb-adapter>` in the env file. The service runs with `dialout` access so the non-root app user can open the USB serial device.

LoRa receiver runtime defaults:

| Key | Default |
| --- | --- |
| `LORA_BAUDRATE` | `9600` |
| `LORA_SERIAL_TIMEOUT_SECONDS` | `1.0` |
| `LORA_READ_SIZE` | `256` |
| `LORA_RECONNECT_DELAY_SECONDS` | `2.0` |
| `LORA_MAX_FRAME_SIZE` | `1024` |
| `LORA_DEDUP_RECENT_FRAMES` | `32` |
| `LORA_COMMAND_MAX_ATTEMPTS` | `3` |
| `LORA_COMMAND_RETRY_DELAY_SECONDS` | `6.0` |
| `LORA_STATUS_PATH` | `<repo>/ruby_service/tmp/lora_receiver_status.json` |
| `LORA_STATUS_HEARTBEAT_SECONDS` | `30.0` |
| `LORA_STATUS_STALE_AFTER_SECONDS` | `120` |

When `LORA_ENABLED=true`, Rails reads the LoRa receiver status file and shows missing, invalid, stale, degraded, or stopped gateway state on the Health page. Wi-Fi-only installs should keep `LORA_ENABLED=false`, which leaves LoRa health disabled rather than alerting.

## LoRa Inbound Manual Validation

Use this after wiring a Pico/LR22 pair and installing the Pi receiver service.

1. Confirm the Pi service is active:

```bash
sudo systemctl status victory-garden-lora-receiver.service --no-pager
```

2. Confirm the configured stable serial path exists:

```bash
set -a
source <(sudo grep -E '^LORA_SERIAL_PORT=' /etc/victory_garden.env)
set +a
ls -l "$LORA_SERIAL_PORT"
```

3. Watch the expected MQTT topic from the Pi:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_sub -R -h 127.0.0.1 -p 1883 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/+/nodes/+/state' -v
```

4. Send one newline-terminated `node-state/v1` JSON frame from the Pico side over LoRa:

```json
{"schema_version":"node-state/v1","timestamp":"2026-08-21T15:20:00Z","zone_id":"zone1","node_id":"lora-bridge-test","moisture_raw":2345,"moisture_percent":55,"health":"ok","last_error":"none","publish_reason":"lora_bridge_ingest_test"}
```

The frame must include a trailing newline when sent over serial.

5. Check the receiver logs:

```bash
sudo journalctl -u victory-garden-lora-receiver.service -n 50 --no-pager
```

Expected events include:

- `serial_connected`
- `frame_received`
- `frame_published`

6. Confirm Rails ingestion after the node is assigned to a zone.

Rails creates or updates the node from MQTT, but historical `sensor_readings` rows depend on the node being assigned/configured for the intended zone. If a valid MQTT payload appears but no reading is stored, check the node assignment before debugging LoRa.

## LoRa Outbound Manual Validation

Use this after the LoRa receiver service is active and the Pi-connected LR22 serial path exists.

1. Publish one LoRa command request to the Pi broker:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_pub -h 127.0.0.1 -p 1883 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -q 1 \
  -t 'greenhouse/nodes/sensor-zone1-ch0/lora/command' \
  -m '{"schema_version":"lora-command/v1","message_id":"pi-manual-test-001","timestamp":"2026-08-21T18:05:00Z","source":"pi-gateway","target_node_id":"sensor-zone1-ch0","command":"request_reading","args":{}}'
```

2. Check the receiver logs:

```bash
sudo journalctl -u victory-garden-lora-receiver.service -n 50 --no-pager
```

Expected events include:

- `lora_command_received`
- `lora_command_routed`

If the serial adapter is disconnected, the command is dropped and logged with reason `serial_disconnected`.

Notes:

- Manual LoRa command tests use retained MQTT messages so a sleeping or
  restarting gateway can see them. Clear a test command after a successful run
  so it does not replay on the next receiver restart:

```bash
mosquitto_pub -h 127.0.0.1 -p 1883 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -q 1 -r -n \
  -t 'greenhouse/nodes/sensor-zone1-ch0/lora/command'
```

- The install script expects a Ruby version compatible with Rails 8. If the distro Ruby is too old, the script stops with a clear error.
- Release tarballs also pin the exact Ruby and Python versions used to build the packaged artifacts.
- Packaged release installs do not fall back to rebuilding Rails gems on the Pi. If `bundle check` fails, rebuild the tarball on a matching Linux ARM host.
- Production mode is configured for local Pi use without forced HTTPS by default. `RAILS_FORCE_SSL` and `RAILS_ASSUME_SSL` can be turned on later in `/etc/victory_garden.env`.
