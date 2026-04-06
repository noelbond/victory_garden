#!/usr/bin/env bash
set -euo pipefail

export PAGER=cat
APP_DB="ruby_service_production"
ZONE_ID="${ZONE_ID:-zone1}"
NODE_ID="${NODE_ID:-pico-w-zone1}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-1}"
ACTUATOR_PREFIX="${ZONE_ID}-actuator-validation-"
REQUEST_READING_PREFIX="${ZONE_ID}-request-reading-validation-"
COMMAND_TOPIC="greenhouse/zones/${ZONE_ID}/command"

case "$MAX_AGE_DAYS" in
  ''|*[!0-9]*)
    echo "MAX_AGE_DAYS must be an integer" >&2
    exit 1
    ;;
esac

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

ACTUATOR_PREFIX_SQL="$(sql_escape "$ACTUATOR_PREFIX")"

MQTT_ARGS=(-h 127.0.0.1)
if [[ -n "${MQTT_USERNAME:-}" ]]; then
  MQTT_ARGS+=(-u "$MQTT_USERNAME")
fi
if [[ -n "${MQTT_PASSWORD:-}" ]]; then
  MQTT_ARGS+=(-P "$MQTT_PASSWORD")
fi

before_statuses="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select count(*)
from actuator_statuses
where idempotency_key like '${ACTUATOR_PREFIX_SQL}%'
  and recorded_at < now() - interval '${MAX_AGE_DAYS} days';
")"

before_events="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select count(*)
from watering_events
where idempotency_key like '${ACTUATOR_PREFIX_SQL}%'
  and created_at < now() - interval '${MAX_AGE_DAYS} days';
")"

before_request_readings="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select count(*)
from sensor_readings
where node_id = '$(sql_escape "$NODE_ID")'
  and publish_reason = 'request_reading'
  and recorded_at < now() - interval '${MAX_AGE_DAYS} days';
")"

sudo -u postgres psql --pset pager=off -d "$APP_DB" -c "
delete from actuator_statuses
where idempotency_key like '${ACTUATOR_PREFIX_SQL}%'
  and recorded_at < now() - interval '${MAX_AGE_DAYS} days';

delete from watering_events
where idempotency_key like '${ACTUATOR_PREFIX_SQL}%'
  and created_at < now() - interval '${MAX_AGE_DAYS} days';
"

cleared_retained_command="no"
retained_command="$(timeout 3 mosquitto_sub "${MQTT_ARGS[@]}" -t "$COMMAND_TOPIC" -C 1 2>/dev/null || true)"
if [[ "${retained_command:-}" == *"\"command_id\":\"$REQUEST_READING_PREFIX"* ]]; then
  mosquitto_pub "${MQTT_ARGS[@]}" -r -n -t "$COMMAND_TOPIC"
  cleared_retained_command="yes"
fi

printf 'DELETED_ACTUATOR_STATUSES %s\n' "$before_statuses"
printf 'DELETED_WATERING_EVENTS %s\n' "$before_events"
printf 'OLDER_REQUEST_READING_ROWS_NOT_DELETED %s\n' "$before_request_readings"
printf 'CLEARED_RETAINED_REQUEST_READING %s\n' "$cleared_retained_command"
