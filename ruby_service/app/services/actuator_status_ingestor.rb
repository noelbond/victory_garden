class ActuatorStatusIngestor
  def initialize(payload)
    @payload = payload
  end

  def call
    zone = Zone.find_by(zone_id: @payload.fetch("zone_id"))
    raise ArgumentError, "Unknown zone_id: #{@payload['zone_id']}" unless zone

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
  end
end
