class ActuatorStatusIngestor
  def initialize(payload)
    @payload = payload
  end

  def call
    zone = Zone.find_by(zone_id: @payload.fetch("zone_id"))
    raise ArgumentError, "Unknown zone_id: #{@payload['zone_id']}" unless zone

    duplicate_status = find_duplicate_status(zone)
    return duplicate_status if duplicate_status

    status = ActuatorStatus.create!(
      zone: zone,
      state: @payload.fetch("state"),
      recorded_at: @payload.fetch("timestamp"),
      idempotency_key: @payload["idempotency_key"],
      actual_runtime_seconds: @payload["actual_runtime_seconds"],
      flow_ml: @payload["flow_ml"],
      fault_code: @payload["fault_code"],
      fault_detail: @payload["fault_detail"]
    )

    update_watering_event_status(status)

    if status.fault_code.present?
      Fault.create!(
        zone: zone,
        fault_code: status.fault_code,
        detail: status.fault_detail,
        recorded_at: status.recorded_at
      )
    end

    request_fresh_reading(zone, status)

    status
  end

  def update_watering_event_status(status)
    return if status.idempotency_key.blank?

    event = WateringEvent.find_by(idempotency_key: status.idempotency_key)
    return unless event

    mapped = case status.state
             when "ACKNOWLEDGED" then "acknowledged"
             when "RUNNING" then "running"
             when "COMPLETED" then "completed"
             when "STOPPED" then "stopped"
             when "FAULT" then "fault"
             else "unknown"
             end

    event.update!(status: mapped)
    mark_interrupted_run_stopped(event, status) if status.state == "STOPPED"
  end

  def mark_interrupted_run_stopped(event, status)
    return unless event.command == "stop_watering"

    WateringEvent
      .where(zone: event.zone, command: "start_watering")
      .where.not(status: ActuatorCommandTimeoutJob::TERMINAL_STATUSES)
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
      issued_at: day_scope
    ).sum(:runtime_seconds)
    runtime_today >= zone.crop_profile.daily_max_runtime_sec
  end
end
