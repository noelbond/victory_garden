#!/usr/bin/env bash
set -euo pipefail

APP_DB="ruby_service_production"
export PAGER=cat
CHECK_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_TMP_DIR"' EXIT

if [[ -r /etc/victory_garden.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/victory_garden.env
  set +a
fi

MQTT_ARGS=(-h 127.0.0.1)
if [[ -n "${MQTT_USERNAME:-}" ]]; then
  MQTT_ARGS+=(-u "$MQTT_USERNAME")
fi
if [[ -n "${MQTT_PASSWORD:-}" ]]; then
  MQTT_ARGS+=(-P "$MQTT_PASSWORD")
fi

if [[ "${LORA_ENABLED:-false}" == "true" ]]; then
  systemctl is-active greenhouse.service victory-garden-mqtt-discovery.service victory-garden-web.service victory-garden-mqtt-consumer.service victory-garden-lora-receiver.service
else
  systemctl is-active greenhouse.service victory-garden-mqtt-discovery.service victory-garden-web.service victory-garden-mqtt-consumer.service
fi

printf 'LORA_ENABLED %s\n' "${LORA_ENABLED:-false}"
if [[ "${LORA_ENABLED:-false}" != "true" ]]; then
  printf 'LORA_SERIAL_PRESENT skipped (LORA_ENABLED is not true)\n'
else
  printf 'LORA_SERIAL_PORT %s\n' "${LORA_SERIAL_PORT:-unset}"
  if [[ -z "${LORA_SERIAL_PORT:-}" || "$LORA_SERIAL_PORT" == "/dev/serial/by-id/REPLACE_WITH_LORA_ADAPTER" ]]; then
    printf 'LORA_SERIAL_PRESENT no\n' >&2
    printf 'ERROR missing stable LORA_SERIAL_PORT in /etc/victory_garden.env\n' >&2
    find /dev/serial/by-id -maxdepth 1 -type l -print 2>/dev/null | sort || true
    exit 1
  fi

  if [[ ! -e "$LORA_SERIAL_PORT" ]]; then
    printf 'LORA_SERIAL_PRESENT no\n' >&2
    printf 'ERROR LORA_SERIAL_PORT does not exist: %s\n' "$LORA_SERIAL_PORT" >&2
    find /dev/serial/by-id -maxdepth 1 -type l -print 2>/dev/null | sort || true
    exit 1
  fi

  printf 'LORA_SERIAL_PRESENT yes\n'
  ls -l "$LORA_SERIAL_PORT"
fi

for _ in $(seq 1 15); do
  if curl -fsS http://127.0.0.1:3000/up >"$CHECK_TMP_DIR/up.out" 2>/dev/null; then
    break
  fi
  sleep 1
done

printf 'UP %s\n' "$(curl -s -o "$CHECK_TMP_DIR/up.out" -w '%{http_code}' http://127.0.0.1:3000/up)"
printf 'ROOT %s\n' "$(curl -s -o "$CHECK_TMP_DIR/root.out" -w '%{http_code}' http://127.0.0.1:3000/)"
printf 'ROOT_HAS_ZONES %s\n' "$(grep -qi zones "$CHECK_TMP_DIR/root.out" && echo yes || echo no)"

sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select 'zones=' || count(*) from zones;
select 'crop_profiles=' || count(*) from crop_profiles;
select 'connection_settings=' || count(*) from connection_settings;
select 'sensor_readings=' || count(*) from sensor_readings;
select 'nodes=' || count(*) from nodes;
"

before="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "select count(*) from sensor_readings")"

mosquitto_pub "${MQTT_ARGS[@]}" -t greenhouse/zones/zone1/nodes/pico-w-zone1/state -m '{"schema_version":"node-state/v1","timestamp":"2026-03-25T15:20:00Z","zone_id":"zone1","node_id":"pico-w-zone1","moisture_raw":354,"moisture_percent":17,"soil_temp_c":26.45,"battery_voltage":2.56,"battery_percent":0,"wifi_rssi":-54,"uptime_seconds":12,"wake_count":1,"ip":"192.168.4.25","health":"degraded","last_error":"none","publish_reason":"scheduled"}'

sleep 5

sudo -u postgres psql --pset pager=off -d "$APP_DB" -c "
update nodes
set zone_id = (select id from zones where zone_id = 'zone1')
where node_id = 'pico-w-zone1'
  and zone_id is null;
"

mosquitto_pub "${MQTT_ARGS[@]}" -t greenhouse/zones/zone1/nodes/pico-w-zone1/state -m '{"schema_version":"node-state/v1","timestamp":"2026-03-25T15:20:10Z","zone_id":"zone1","node_id":"pico-w-zone1","moisture_raw":354,"moisture_percent":17,"soil_temp_c":26.45,"battery_voltage":2.56,"battery_percent":0,"wifi_rssi":-54,"uptime_seconds":22,"wake_count":2,"ip":"192.168.4.25","health":"degraded","last_error":"none","publish_reason":"scheduled"}'

sleep 5

after="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "select count(*) from sensor_readings")"

printf 'SENSOR_READINGS_BEFORE %s\n' "$before"
printf 'SENSOR_READINGS_AFTER %s\n' "$after"

sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select 'latest_node=' || coalesce(node_id, '') || ',zone=' || coalesce(zone_id::text, '') || ',moisture=' || coalesce(moisture_percent::text, '')
from sensor_readings
order by recorded_at desc
limit 1;
select 'node_registry=' || count(*) from nodes;
"

journalctl -u greenhouse.service -n 10 --no-pager
journalctl -u victory-garden-mqtt-discovery.service -n 10 --no-pager
journalctl -u victory-garden-mqtt-consumer.service -n 10 --no-pager
if [[ "${LORA_ENABLED:-false}" == "true" ]]; then
  journalctl -u victory-garden-lora-receiver.service -n 20 --no-pager
fi
