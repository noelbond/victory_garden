class CommandPublishJob < ApplicationJob
  queue_as :default
  # MQTT::Exception is caught explicitly alongside StandardError because the
  # mqtt gem's exceptions inherit from Ruby's root Exception, not
  # StandardError -- retry_on alone would silently never catch a genuine
  # MQTT protocol/connection failure. Pre-existing gap (not introduced
  # today), found while adding the same retry_on pattern elsewhere.
  retry_on StandardError, MQTT::Exception, attempts: 3, wait: 5.seconds

  def perform(command)
    MqttClient.publish_command(command)
    mark_event_command_sent(command)
  end

  private

  def mark_event_command_sent(command)
    idempotency_key = command[:idempotency_key] || command["idempotency_key"]
    return if idempotency_key.blank?

    WateringEvent.where(idempotency_key: idempotency_key, status: "queued")
      .update_all(status: "command_sent", updated_at: Time.current)
  end
end
