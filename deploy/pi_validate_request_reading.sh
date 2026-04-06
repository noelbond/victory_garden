#!/usr/bin/env bash
set -euo pipefail

export PAGER=cat
APP_DB="ruby_service_production"
ZONE_ID="${ZONE_ID:-zone1}"
NODE_ID="${NODE_ID:-pico-w-zone1}"
COMMAND_ID="${COMMAND_ID:-${ZONE_ID}-request-reading-validation-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMAND_TOPIC="greenhouse/zones/${ZONE_ID}/command"

print_consumer_logs() {
  local logs
  logs="$(journalctl -u victory-garden-mqtt-consumer.service --since "$STARTED_AT" --no-pager -o cat 2>/dev/null | tail -n 20 || true)"
  printf 'CONSUMER_LOGS_BEGIN\n'
  if [[ -n "${logs//[$'\n\r\t ']}" ]]; then
    printf '%s\n' "$logs"
  else
    printf 'none\n'
  fi
  printf 'CONSUMER_LOGS_END\n'
}

MQTT_ARGS=(-h 127.0.0.1)
if [[ -n "${MQTT_USERNAME:-}" ]]; then
  MQTT_ARGS+=(-u "$MQTT_USERNAME")
fi
if [[ -n "${MQTT_PASSWORD:-}" ]]; then
  MQTT_ARGS+=(-P "$MQTT_PASSWORD")
fi

before_count="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select count(*)
from sensor_readings
where node_id = '$NODE_ID'
  and publish_reason = 'request_reading'
  and recorded_at >= '$STARTED_AT';
")"

mosquitto_pub "${MQTT_ARGS[@]}" -r \
  -t "$COMMAND_TOPIC" \
  -m "{\"schema_version\":\"node-command/v1\",\"command\":\"request_reading\",\"command_id\":\"$COMMAND_ID\"}"

retained_command="$(timeout 3 mosquitto_sub "${MQTT_ARGS[@]}" -t "$COMMAND_TOPIC" -C 1 2>/dev/null || true)"

sleep 8

after_count="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select count(*)
from sensor_readings
where node_id = '$NODE_ID'
  and publish_reason = 'request_reading'
  and recorded_at >= '$STARTED_AT';
")"

printf 'REQUEST_READING_BEFORE %s\n' "$before_count"
printf 'REQUEST_READING_AFTER %s\n' "$after_count"
printf 'COMMAND_ID %s\n' "$COMMAND_ID"
printf 'STARTED_AT %s\n' "$STARTED_AT"
printf 'RETAINED_COMMAND %s\n' "${retained_command:-NONE}"

sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select 'latest=' ||
  coalesce(node_id, '') ||
  ',recorded_at=' || coalesce(to_char(recorded_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '') ||
  ',moisture=' || coalesce(moisture_percent::text, 'NULL') ||
  ',reason=' || coalesce(publish_reason, 'NULL')
from sensor_readings
where node_id = '$NODE_ID'
  and publish_reason = 'request_reading'
  and recorded_at >= '$STARTED_AT'
order by recorded_at desc
limit 1;
"

cleared_retained_command="no"
latest_retained_command="$(timeout 3 mosquitto_sub "${MQTT_ARGS[@]}" -t "$COMMAND_TOPIC" -C 1 2>/dev/null || true)"
if [[ "${latest_retained_command:-}" == *"\"command_id\":\"$COMMAND_ID\""* ]]; then
  mosquitto_pub "${MQTT_ARGS[@]}" -r -n -t "$COMMAND_TOPIC"
  cleared_retained_command="yes"
fi
printf 'CLEARED_RETAINED_COMMAND %s\n' "$cleared_retained_command"

print_consumer_logs
