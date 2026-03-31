class ControllerEventIngestJob < ApplicationJob
  queue_as :default

  def perform(payload)
    ControllerEventIngestor.new(payload).call
  end
end
