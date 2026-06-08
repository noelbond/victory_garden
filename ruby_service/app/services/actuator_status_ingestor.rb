class ActuatorStatusIngestor
  STATUS_MAPPING = {
    "ACKNOWLEDGED" => "acknowledged",
    "RUNNING" => "running",
    "COMPLETED" => "completed",
    "STOPPED" => "stopped",
    "FAULT" => "fault"
  }.freeze
  STATUS_SEQUENCE = %w[queued command_sent acknowledged running completed].freeze
  def initialize(payload)
    @payload = PayloadContracts::ActuatorStatus.normalize!(payload)
  end

  def call
    zone = Zone.find_by(zone_id: @payload.fetch("zone_id"))
    raise ArgumentError, "Unknown zone_id: #{@payload['zone_id']}" unless zone

    duplicate_status = find_duplicate_status(zone)
    return duplicate_status if duplicate_status

    status = ActiveRecord::Base.transaction do
      status = begin
        ActuatorStatus.create!(
          zone: zone,
          state: @payload.fetch("state"),
          recorded_at: @payload.fetch("timestamp"),
          idempotency_key: @payload["idempotency_key"],
          actual_runtime_seconds: @payload["actual_runtime_seconds"],
          flow_ml: @payload["flow_ml"],
          fault_code: @payload["fault_code"],
          fault_detail: @payload["fault_detail"]
        )
      rescue ActiveRecord::RecordNotUnique
        find_duplicate_status(zone) || raise
      end

      update_watering_event_status(status)
      record_fault_if_needed(zone, status)
      status
    end

    request_fresh_reading(zone, status)

    status
  end

  private

  def update_watering_event_status(status)
    return if status.idempotency_key.blank?

    event = WateringEvent.find_by(idempotency_key: status.idempotency_key)
    return unless event

    mapped = STATUS_MAPPING.fetch(status.state, "unknown")
    return unless transition_allowed?(event, mapped, source_state: status.state)

    event.update!(status: mapped)
    mark_interrupted_run_stopped(event, status) if status.state == "STOPPED"
  end

  def mark_interrupted_run_stopped(event, status)
    return unless event.command == "stop_watering"

    WateringEvent
      .where(zone: event.zone, command: "start_watering")
      .where.not(status: WateringEvent::TERMINAL_STATUSES)
      .where("issued_at <= ?", status.recorded_at)
      .order(issued_at: :desc)
      .limit(1)
      .update_all(status: "stopped", updated_at: Time.current)
  end

  def find_duplicate_status(zone)
    return nil if @payload["idempotency_key"].blank?

    ActuatorStatus.find_by(
      zone: zone,
      idempotency_key: @payload["idempotency_key"],
      state: @payload.fetch("state")
    )
  end

  def record_fault_if_needed(zone, status)
    return unless status.fault_code.present?

    existing = Fault.find_by(
      zone: zone,
      fault_code: status.fault_code,
      detail: status.fault_detail,
      resolved_at: nil
    )
    return existing if existing

    Fault.create!(
      zone: zone,
      fault_code: status.fault_code,
      detail: status.fault_detail,
      recorded_at: status.recorded_at
    )
  end

  def transition_allowed?(event, mapped_status, source_state:)
    current_status = event.status.presence || "queued"
    return true if current_status == mapped_status

    if terminal_status?(current_status) && current_status != mapped_status
      Rails.logger.warn(
        "[actuator_status_ingestor] Ignoring actuator state #{source_state} for #{event.idempotency_key}: " \
        "event already terminal at #{current_status}"
      )
      return false
    end

    return true unless sequenced_status?(current_status) && sequenced_status?(mapped_status)

    current_index = STATUS_SEQUENCE.index(current_status)
    next_index = STATUS_SEQUENCE.index(mapped_status)

    if next_index < current_index
      Rails.logger.warn(
        "[actuator_status_ingestor] Ignoring out-of-order actuator state #{source_state} for #{event.idempotency_key}: " \
        "#{current_status} -> #{mapped_status}"
      )
      return false
    end

    if next_index > current_index + 1
      Rails.logger.warn(
        "[actuator_status_ingestor] Accepting non-sequential actuator state #{source_state} for #{event.idempotency_key}: " \
        "#{current_status} -> #{mapped_status}"
      )
    end

    true
  end

  def terminal_status?(status)
    WateringEvent::TERMINAL_STATUSES.include?(status)
  end

  def sequenced_status?(status)
    STATUS_SEQUENCE.include?(status)
  end

  def request_fresh_reading(zone, status)
    return unless status.state == "COMPLETED"
    return if status.idempotency_key.blank?
    return if daily_runtime_met?(zone, status.recorded_at)

    RequestReadingJob.set(wait: 5.minutes).perform_later(
      zone_id: zone.zone_id,
      command_id: "#{status.idempotency_key}-reread"
    )
  end

  def daily_runtime_met?(zone, time)
    day_scope = time.beginning_of_day..time.end_of_day
    runtime_today = WateringEvent.where(
      zone: zone,
      command: "start_watering",
      status: "completed",
      issued_at: day_scope
    ).sum(:runtime_seconds)
    runtime_today >= zone.crop_profile.daily_max_runtime_sec
  end
end
