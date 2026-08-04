class RebootNodeJob < ApplicationJob
  queue_as :default
  # MQTT::Exception is caught explicitly alongside StandardError because the
  # mqtt gem's exceptions inherit from Ruby's root Exception, not
  # StandardError -- retry_on alone would silently never catch a genuine
  # MQTT protocol/connection failure.
  retry_on StandardError, MQTT::Exception, attempts: 3, wait: 5.seconds

  TIMEOUT_SECONDS = 30

  def perform(zone_id:, command_id:, node_id:)
    MqttClient.reboot_node(zone_id: zone_id, command_id: command_id, node_id: node_id)

    NodeCommand.where(command_id: command_id, status: "queued")
      .update_all(status: "command_sent", updated_at: Time.current)
  end
end
