#!/usr/bin/env bash
set -euo pipefail

export PAGER=cat
APP_DB="ruby_service_production"
NODE_ID="${1:-pi-test-node}"

before="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "select count(*) from sensor_readings")"

sudo -u postgres psql --pset pager=off -d "$APP_DB" -c "
update nodes
set zone_id = (select id from zones where zone_id = 'zone1')
where node_id = '$NODE_ID';
"

mosquitto_pub -h 127.0.0.1 -t greenhouse/zones/zone1/state -m "{\"schema_version\":\"node-state/v1\",\"timestamp\":\"2026-03-25T15:25:00Z\",\"zone_id\":\"zone1\",\"node_id\":\"$NODE_ID\",\"moisture_raw\":333,\"moisture_percent\":19,\"soil_temp_c\":24.2,\"battery_voltage\":3.91,\"battery_percent\":76,\"wifi_rssi\":-51,\"uptime_seconds\":240,\"wake_count\":4,\"ip\":\"192.168.4.99\",\"health\":\"ok\",\"last_error\":\"none\",\"publish_reason\":\"scheduled\"}"

sleep 5

after="$(sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "select count(*) from sensor_readings")"

printf 'SENSOR_READINGS_BEFORE %s\n' "$before"
printf 'SENSOR_READINGS_AFTER %s\n' "$after"

sudo -u postgres psql --pset pager=off -d "$APP_DB" -Atc "
select 'node=' || node_id || ',zone_id=' || coalesce(zone_id::text, 'NULL') || ',reported_zone_id=' || coalesce(reported_zone_id, 'NULL')
from nodes
where node_id = '$NODE_ID';
select 'latest=' || coalesce(node_id, '') || ',zone=' || coalesce(zone_id::text, '') || ',moisture=' || coalesce(moisture_percent::text, '')
from sensor_readings
order by recorded_at desc
limit 1;
"

journalctl -u victory-garden-mqtt-consumer.service -n 20 --no-pager
