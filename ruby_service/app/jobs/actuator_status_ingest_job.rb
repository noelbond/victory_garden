class ActuatorStatusIngestJob < ApplicationJob
  queue_as :default

  def perform(payload)
    ActuatorStatusIngestor.new(payload).call
  end
end
