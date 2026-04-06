class CommandPublishJob < ApplicationJob
  queue_as :default
  retry_on StandardError, attempts: 3, wait: 5.seconds

  def perform(command)
    MqttClient.publish_command(command)
    mark_event_command_sent(command)
    schedule_timeout_watchdog(command)
  end

  private

  def mark_event_command_sent(command)
    idempotency_key = command[:idempotency_key] || command["idempotency_key"]
    return if idempotency_key.blank?

    WateringEvent.where(idempotency_key: idempotency_key, status: "queued")
      .update_all(status: "command_sent", updated_at: Time.current)
  end

  def schedule_timeout_watchdog(command)
    idempotency_key = command[:idempotency_key] || command["idempotency_key"]
    return if idempotency_key.blank?

    timeout_seconds = timeout_window(command)
    ActuatorCommandTimeoutJob
      .set(wait: timeout_seconds.seconds)
      .perform_later(idempotency_key: idempotency_key, timeout_seconds: timeout_seconds)
  end

  def timeout_window(command)
    runtime_seconds = command[:runtime_seconds] || command["runtime_seconds"]
    runtime_seconds = runtime_seconds.to_i

    if runtime_seconds.positive?
      [runtime_seconds + 30, 60].max
    else
      30
    end
  end
end
