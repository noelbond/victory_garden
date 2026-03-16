class RequestReadingJob < ApplicationJob
  queue_as :default

  def perform(zone_id:, command_id:)
    MqttClient.request_reading(zone_id: zone_id, command_id: command_id)
  end
end
