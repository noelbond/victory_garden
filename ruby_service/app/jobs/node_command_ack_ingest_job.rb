class NodeCommandAckIngestJob < ApplicationJob
  queue_as :default

  def perform(payload)
    NodeCommandAckIngestor.new(payload).call
  end
end
