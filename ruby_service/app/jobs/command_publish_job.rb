class CommandPublishJob < ApplicationJob
  queue_as :default
  retry_on StandardError, attempts: 3, wait: 5.seconds

  def perform(command)
    MqttClient.publish_command(command)
  end
end
