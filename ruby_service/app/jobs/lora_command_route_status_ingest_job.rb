class LoraCommandRouteStatusIngestJob < ApplicationJob
  queue_as :default

  # Route-status events are mostly diagnostic, but a transient DB failure is
  # still worth retrying before recording that ingestion itself failed.
  retry_on StandardError, attempts: 3, wait: 5.seconds do |job, error|
    payload = job.arguments.first
    Fault.create!(
      zone: Zone.find_by(zone_id: payload["zone_id"] || payload[:zone_id]),
      node_id: payload["target_node_id"] || payload[:target_node_id],
      fault_code: "LORA_COMMAND_ROUTE_STATUS_INGEST_FAILED",
      detail: "LoRa command route status ingest failed after 3 attempts: #{error.class}: #{error.message}",
      recorded_at: Time.current
    )
  end

  def perform(payload)
    LoraCommandRouteStatusIngestor.new(payload).call
  end
end
