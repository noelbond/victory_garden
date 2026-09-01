class RequestReadingJob < ApplicationJob
  queue_as :default
  # MQTT::Exception is caught explicitly alongside StandardError because the
  # mqtt gem's exceptions inherit from Ruby's root Exception, not
  # StandardError -- retry_on alone would silently never catch a genuine
  # MQTT protocol/connection failure.
  retry_on StandardError, MQTT::Exception, attempts: 3, wait: 5.seconds

  TIMEOUT_SECONDS = 30

  def perform(zone_id:, command_id:, node_id: nil)
    node = Node.find_by(node_id: node_id) if node_id.present?

    if node&.lora_transport?
      MqttClient.request_lora_reading(node_id: node.node_id, command_id: command_id)
    else
      MqttClient.request_reading(zone_id: zone_id, command_id: command_id, node_id: node_id)
    end

    # A no-op for callers that don't track this command_id via NodeCommand
    # (e.g. the onboarding wizard's own request_reading trigger).
    NodeCommand.where(command_id: command_id, status: "queued")
      .update_all(status: "command_sent", updated_at: Time.current)
  end
end
