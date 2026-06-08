# Victory Garden Logging Guide

This guide puts the main live and local logs in one place.

Use it when you need to answer:

- Is the Python controller running?
- Is the Rails web app healthy?
- Is the Rails MQTT consumer ingesting messages?
- Is Mosquitto receiving and forwarding MQTT traffic?
- Is a sensor node publishing?
- Is an actuator command being sent and acknowledged?

## 1. Live Pi Logs

The deployed Pi stack writes its important runtime logs to the `systemd` journal.

### Python automatic controller

```bash
sudo journalctl -u greenhouse.service -n 100 --no-pager
```

Live tail:

```bash
sudo journalctl -u greenhouse.service -f
```

What you will see:

- controller startup and shutdown
- watering decisions
- skipped decisions and reasons
- reread requests
- MQTT lifecycle events from the Python controller

### Rails web app

```bash
sudo journalctl -u victory-garden-web.service -n 100 --no-pager
```

Live tail:

```bash
sudo journalctl -u victory-garden-web.service -f
```

What you will see:

- Rails boot output
- request errors
- app exceptions
- web service restarts

### Rails MQTT consumer

```bash
sudo journalctl -u victory-garden-mqtt-consumer.service -n 100 --no-pager
```

Live tail:

```bash
sudo journalctl -u victory-garden-mqtt-consumer.service -f
```

What you will see:

- MQTT subscribe/connect output
- ingest warnings
- invalid JSON errors
- unknown-topic or consumer-side processing failures

### MQTT discovery responder

```bash
sudo journalctl -u victory-garden-mqtt-discovery.service -n 100 --no-pager
```

Live tail:

```bash
sudo journalctl -u victory-garden-mqtt-discovery.service -f
```

What you will see:

- UDP discovery responder startup
- broker IP/port discovery behavior
- service restarts

### Mosquitto broker

```bash
sudo journalctl -u mosquitto -n 100 --no-pager
```

Live tail:

```bash
sudo journalctl -u mosquitto -f
```

What you will see:

- broker startup and auth problems
- listener failures
- client connect and disconnect events

## 2. MQTT Traffic View

If you want to see the actual live MQTT traffic instead of service logs, subscribe directly to the broker.

Load broker auth from the Pi environment:

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
```

Subscribe to all Victory Garden MQTT traffic:

```bash
mosquitto_sub -h 127.0.0.1 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/#' -v
```

Useful filtered views:

### Sensor node state

```bash
mosquitto_sub -h 127.0.0.1 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/+/nodes/+/state' -v
```

### Node commands and acknowledgements

```bash
mosquitto_sub -h 127.0.0.1 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/+/command' -t 'greenhouse/zones/+/command_ack' -v
```

### Actuator commands and status

```bash
mosquitto_sub -h 127.0.0.1 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/+/actuator/command' -t 'greenhouse/zones/+/actuator/status' -v
```

### Controller decisions

```bash
mosquitto_sub -h 127.0.0.1 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/zones/+/controller/event' -t 'greenhouse/zones/+/controller/skip' -v
```

## 3. Local Development Logs

For the local Rails app:

```bash
tail -n 100 ruby_service/log/development.log
```

Live tail:

```bash
tail -f ruby_service/log/development.log
```

For local Rails commands in development:

```bash
cd ruby_service
./bin/dev-rails s
./bin/dev-rails test
```

Those print directly in the terminal as well as writing the normal Rails log.

## 4. Quick Triage

Use these checks in order.

### Problem: The UI shows stale nodes or stale readings

Check:

1. `sudo journalctl -u greenhouse.service -n 50 --no-pager`
2. `sudo journalctl -u victory-garden-mqtt-consumer.service -n 50 --no-pager`
3. `mosquitto_sub ... -t 'greenhouse/zones/+/nodes/+/state' -v`

You want to know:

- Is the node still publishing?
- Is the consumer still ingesting?
- Is the controller reacting?

### Problem: Config sync failed

Check:

1. `sudo journalctl -u victory-garden-web.service -n 50 --no-pager`
2. `sudo journalctl -u victory-garden-mqtt-consumer.service -n 50 --no-pager`
3. `sudo journalctl -u mosquitto -n 50 --no-pager`

You want to know:

- Did Rails publish config?
- Did the node ACK it?
- Did the broker reject auth or disconnect the client?

### Problem: Watering did not happen

Check:

1. `sudo journalctl -u greenhouse.service -n 100 --no-pager`
2. `mosquitto_sub ... -t 'greenhouse/zones/+/controller/event' -t 'greenhouse/zones/+/controller/skip' -v`
3. `mosquitto_sub ... -t 'greenhouse/zones/+/actuator/command' -t 'greenhouse/zones/+/actuator/status' -v`

You want to know:

- Did the controller decide to water?
- If not, why was it skipped?
- If yes, did the actuator command go out?
- Did the actuator report `ACKNOWLEDGED`, `RUNNING`, or `COMPLETED`?

## 5. Best Single Commands

If you only remember a few commands, use these:

### Last 50 lines from all important Pi services

```bash
sudo journalctl -u greenhouse.service \
  -u victory-garden-web.service \
  -u victory-garden-mqtt-consumer.service \
  -u victory-garden-mqtt-discovery.service \
  -u mosquitto \
  -n 50 --no-pager
```

### Live MQTT wire view

```bash
set -a
source <(sudo grep -E '^(MQTT_USERNAME|MQTT_PASSWORD)=' /etc/victory_garden.env)
set +a
mosquitto_sub -h 127.0.0.1 -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -t 'greenhouse/#' -v
```

### Controller-only live tail

```bash
sudo journalctl -u greenhouse.service -f
```
