class RebootNodeJob < ApplicationJob
  queue_as :default

  def perform(zone_id:, command_id:, node_id:)
    MqttClient.reboot_node(zone_id: zone_id, command_id: command_id, node_id: node_id)
  end
end
