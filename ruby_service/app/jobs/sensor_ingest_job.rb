class SensorIngestJob < ApplicationJob
  queue_as :default

  def perform(payload)
    SensorIngestor.new(payload).call
  end
end
