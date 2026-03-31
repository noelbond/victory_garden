class ActuatorCommandTimeoutJob < ApplicationJob
  queue_as :default

  TERMINAL_STATUSES = %w[completed stopped fault timeout].freeze

  def perform(idempotency_key:, timeout_seconds:)
    event = WateringEvent.includes(:zone).find_by(idempotency_key: idempotency_key)
    return unless event
    return if TERMINAL_STATUSES.include?(event.status)

    event.update!(status: "timeout")

    Fault.create!(
      zone: event.zone,
      fault_code: "ACTUATOR_TIMEOUT",
      detail: "No actuator status received within #{timeout_seconds}s for #{event.command} (#{idempotency_key})",
      recorded_at: Time.current
    )
  end
end
