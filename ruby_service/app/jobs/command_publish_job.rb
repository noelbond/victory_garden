class CommandPublishJob < ApplicationJob
  queue_as :default

  def perform(command)
    MqttClient.publish_command(command)
  end
end
