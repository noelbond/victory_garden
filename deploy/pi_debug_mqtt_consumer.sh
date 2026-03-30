#!/usr/bin/env bash
set -euo pipefail

export PAGER=cat

systemctl status victory-garden-mqtt-consumer.service --no-pager --full || true
journalctl -u victory-garden-mqtt-consumer.service -n 80 --no-pager

sudo -u postgres psql --pset pager=off -d ruby_service_production -Atc "
select 'node=' || node_id ||
       ',zone_id=' || coalesce(zone_id::text, 'NULL') ||
       ',reported_zone_id=' || coalesce(reported_zone_id, 'NULL') ||
       ',last_seen_at=' || coalesce(to_char(last_seen_at, 'YYYY-MM-DD HH24:MI:SS'), 'NULL')
from nodes;
"
