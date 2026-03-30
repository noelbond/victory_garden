#!/usr/bin/env bash
set -euo pipefail

export PAGER=cat

sudo -u postgres psql --pset pager=off -d ruby_service_production_queue -Atc "
select 'jobs=' || count(*) from solid_queue_jobs;
select 'ready=' || count(*) from solid_queue_ready_executions;
select 'scheduled=' || count(*) from solid_queue_scheduled_executions;
select 'processes=' || count(*) from solid_queue_processes;
select 'latest_job=' || coalesce(class_name, '') || ',queue=' || coalesce(queue_name, '') || ',active_job_id=' || coalesce(active_job_id, '')
from solid_queue_jobs
order by id desc
limit 1;
"

journalctl -u victory-garden-web.service -n 40 --no-pager
