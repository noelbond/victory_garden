class SensorIngestJob < ApplicationJob
  queue_as :default

  # A malformed/mismatched payload (unknown node_id, unknown zone_id,
  # validation failure) won't be fixed by retrying the identical payload,
  # but a transient DB hiccup might be -- retry_on still covers that case.
  # Either way, once attempts are exhausted, record a fault instead of
  # letting the reading silently vanish into solid_queue_failed_executions.
  retry_on StandardError, attempts: 3, wait: 5.seconds do |job, error|
    payload = job.arguments.first
    Fault.create!(
      zone: Zone.find_by(zone_id: payload["zone_id"] || payload[:zone_id]),
      node_id: payload["node_id"] || payload[:node_id],
      fault_code: "SENSOR_INGEST_FAILED",
      detail: "Sensor reading ingest failed after 3 attempts: #{error.class}: #{error.message}",
      recorded_at: Time.current
    )
  end

  def perform(payload)
    SensorIngestor.new(payload).call
  end
end
