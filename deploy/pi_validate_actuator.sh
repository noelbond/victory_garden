#!/usr/bin/env bash
set -euo pipefail

export PAGER=cat
APP_DB="ruby_service_production"
EVENT_KEY="${EVENT_KEY:-zone1-actuator-validation-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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

zone_pk="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "select id from zones where zone_id='zone1'")"
if [[ -z "$zone_pk" ]]; then
  echo "zone1 missing"
  exit 1
fi

sudo -u postgres psql --pset pager=off -d "$APP_DB" -c "
delete from actuator_statuses where idempotency_key = '$EVENT_KEY';
delete from watering_events where idempotency_key = '$EVENT_KEY';
insert into watering_events (zone_id, command, runtime_seconds, reason, issued_at, idempotency_key, status, created_at, updated_at)
values ($zone_pk, 'start_watering', 2, 'actuator_validation', now(), '$EVENT_KEY', 'command_sent', now(), now());
"

before_status="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "select count(*) from actuator_statuses where idempotency_key = '$EVENT_KEY'")"

mosquitto_pub "${MQTT_ARGS[@]}" -t greenhouse/zones/zone1/actuator/command -m "{\"command\":\"start_watering\",\"zone_id\":\"zone1\",\"runtime_seconds\":2,\"reason\":\"actuator_validation\",\"idempotency_key\":\"$EVENT_KEY\"}"

sleep 4

after_status="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "select count(*) from actuator_statuses where idempotency_key = '$EVENT_KEY'")"

printf 'ACTUATOR_STATUS_BEFORE %s\n' "$before_status"
printf 'ACTUATOR_STATUS_AFTER %s\n' "$after_status"
printf 'EVENT_KEY %s\n' "$EVENT_KEY"
printf 'STARTED_AT %s\n' "$STARTED_AT"

sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select 'event_status=' || coalesce(status, 'NULL') from watering_events where idempotency_key = '$EVENT_KEY';
select 'latest_status=' || state || ',runtime=' || coalesce(actual_runtime_seconds::text, 'NULL')
from actuator_statuses
where idempotency_key = '$EVENT_KEY'
order by recorded_at desc
limit 1;
"

print_consumer_logs
