class RequestReadingJob < ApplicationJob
  queue_as :default

  def perform(zone_id:, command_id:, node_id: nil)
    MqttClient.request_reading(zone_id: zone_id, command_id: command_id, node_id: node_id)
  end
end
