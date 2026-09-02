threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)

plugin :tmp_restart

# Production uses the dedicated victory-garden-jobs.service. Keep this opt-in
# for local deployments that intentionally co-locate Solid Queue with Puma;
# strings such as "0" and "false" must not enable the plugin.
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"] == "true"

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
