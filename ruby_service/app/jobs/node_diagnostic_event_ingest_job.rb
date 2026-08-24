class NodeDiagnosticEventIngestJob < ApplicationJob
  queue_as :default

  # See SensorIngestJob for why this retries at all despite most failures
  # being permanent payload problems, not transient ones.
  retry_on StandardError, attempts: 3, wait: 5.seconds do |job, error|
    payload = job.arguments.first
    Fault.create!(
      zone: Zone.find_by(zone_id: payload["zone_id"] || payload[:zone_id]),
      node_id: payload["node_id"] || payload[:node_id],
      fault_code: "NODE_DIAGNOSTIC_EVENT_INGEST_FAILED",
      detail: "Node diagnostic event ingest failed after 3 attempts: #{error.class}: #{error.message}",
      recorded_at: Time.current
    )
  end

  def perform(payload)
    NodeDiagnosticEventIngestor.new(payload).call
  end
end
