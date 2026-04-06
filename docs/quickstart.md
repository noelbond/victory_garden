# One-Zone Quick Start

This is the fastest path to a working single-zone Victory Garden setup.

It assumes:

- one Raspberry Pi on your LAN
- one actuator zone
- one claimed sensor node
- one claimed actuator node
- Mosquitto and Rails running on the Pi
- one dedicated actuator Pico listening on the actuator topics

If you need the full install flow first, start with [`setup.md`](/Users/noel/coding/python/victory_garden/docs/setup.md).

## 1. Install the Pi stack

On the Pi:

```bash
git clone <your-repo-url> victory_garden
cd victory_garden
sudo ./deploy/install_pi.sh
```

Verify:

```bash
sudo systemctl status mosquitto --no-pager
sudo systemctl status victory-garden-mqtt-discovery.service --no-pager
sudo systemctl status victory-garden-web.service --no-pager
sudo systemctl status victory-garden-mqtt-consumer.service --no-pager
```

Then open:

- `http://<pi-ip>:3000/onboarding`
- `http://<pi-ip>:3000/health`

## 2. Configure the app

In the Rails UI:

1. go to `Settings`
2. confirm:
   - MQTT host points to the Pi broker
   - MQTT port is `1883`
   - MQTT username/password match the Pi broker if auth is enabled
3. create one crop profile if needed
4. create one zone

The health page should show the app is running even before a node is claimed.

## 3. Bring up the sensor and actuator nodes

You need:

- one sensor node:
  - Arduino MKR WiFi 1010 firmware, or
  - Pico W sensor firmware
- one Pico W actuator node

Set each node to publish to the Pi broker IP. If the Pi IP changes later, the Pico firmwares will rediscover it automatically through the Pi's UDP discovery service.

For the Pico builds:

```bash
git submodule update --init --recursive
export PICO_SDK_PATH="$PWD/firmware/pico-sdk"
cmake -S firmware/pico_w_sensor_node -B firmware/pico_w_sensor_node/build -G Ninja -DPICO_BOARD=pico_w
cmake --build firmware/pico_w_sensor_node/build --target pico_w_sensor_node pico_w_actuator_node
```

Before running that, make sure:

- `arm-none-eabi-gcc` is installed and on your `PATH`
- `cmake` and `ninja` are installed

Flash:

- `firmware/pico_w_sensor_node/build/pico_w_sensor_node.uf2` to the sensor Pico
- `firmware/pico_w_sensor_node/build/pico_w_actuator_node.uf2` to the actuator Pico

## 4. Confirm node discovery

On the Pi:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_sub -h localhost -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/+/state' -v
```

You should see retained `node-state/v1` messages from the sensor node.

In Rails:

1. open `Nodes`
2. confirm the sensor node appears
3. claim it to the zone you created

Important:

- unclaimed nodes are visible and updated
- only claimed nodes persist readings and trigger automatic decisions

## 5. Confirm live ingest

After the node is claimed:

- the health page should show the node
- Rails should persist new `sensor_readings`
- the latest reading should appear on the zone page

Useful checks:

- `http://<pi-ip>:3000/health`
- `http://<pi-ip>:3000/zones`

## 6. Trigger one manual watering cycle

In the Rails UI:

1. open the zone
2. click `Water Now`

Expected flow:

1. Rails creates a queued `WateringEvent`
2. Rails publishes `start_watering`
3. the actuator Pico publishes status
4. Rails updates the event
5. after `COMPLETED`, Rails schedules a delayed `request_reading`

Watch the broker:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_sub -h localhost -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/#' -v
```

You should see:

- actuator command
- actuator status
- later, a retained `request_reading`
- a fresh node-state publish

Pi-side validation helpers:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
./deploy/pi_validate_actuator.sh
./deploy/pi_validate_request_reading.sh
./deploy/pi_cleanup_validation_data.sh
```

## 7. Confirm the operator pages

Check:

- `/onboarding`
- `/health`
- the zone detail page

At minimum, these should show:

- claimed node
- latest reading
- watering history
- latest actuator status
- faults if anything failed

## 8. Recommended next checks

Once the one-zone path works, verify:

- broker restart recovery
- Pi reboot recovery
- node reconnect after reboot
- retained command cleanup
- config sync ack behavior

## Current limitation

The software stack is ready for one-zone operation, but the final hardware validation still depends on:

- real moisture sensor wiring and calibration
- real actuator hardware trigger/stop confirmation

Calibration note:

- the Arduino node supports explicit dry/wet calibration in its local config
- the Pico sensor node uses the seesaw I2C moisture sensor with dry/wet calibration bounds in firmware
- see [`calibration.md`](/Users/noel/coding/python/victory_garden/docs/calibration.md)
