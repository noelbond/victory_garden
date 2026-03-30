class NodeConfigAckIngestJob < ApplicationJob
  queue_as :default

  def perform(payload)
    NodeConfigAckIngestor.new(payload).call
  end
end
