class GreenhouseTemperatureAlert
  WARNING_ON_F = 90.0
  WARNING_CLEAR_F = 88.0
  CRITICAL_ON_F = 95.0
  CRITICAL_CLEAR_F = 93.0
  FAULT_CODE = "GREENHOUSE_HIGH_TEMPERATURE"

  def initialize(zone:, temperature_c:, recorded_at:)
    @zone = zone
    @temperature_c = temperature_c
    @recorded_at = recorded_at
  end

  def status
    return "normal" if @temperature_c.nil?

    temperature_f = fahrenheit
    previous_status = previous_reading&.greenhouse_alert_status
    return "critical" if temperature_f > CRITICAL_ON_F

    case previous_status
    when "critical"
      return "critical" if temperature_f >= CRITICAL_CLEAR_F
      return "warning" if temperature_f >= WARNING_CLEAR_F
    when "warning"
      return "warning" if temperature_f >= WARNING_CLEAR_F
    end

    temperature_f > WARNING_ON_F ? "warning" : "normal"
  end

  def record!(status:)
    if status == "critical"
      create_critical_fault_unless_open!
    elsif fahrenheit < CRITICAL_CLEAR_F
      resolve_critical_faults!
    end
  end

  private

  def fahrenheit
    (@temperature_c.to_f * 9.0 / 5.0) + 32.0
  end

  def previous_reading
    @zone.sensor_readings
      .where.not(air_temperature_c: nil)
      .where("recorded_at < ?", @recorded_at)
      .order(recorded_at: :desc, id: :desc)
      .first
  end

  def create_critical_fault_unless_open!
    return if @zone.faults.exists?(fault_code: FAULT_CODE, resolved_at: nil)

    @zone.faults.create!(
      fault_code: FAULT_CODE,
      detail: format("Greenhouse air temperature reached %.1f F.", fahrenheit),
      recorded_at: @recorded_at
    )
  end

  def resolve_critical_faults!
    @zone.faults
      .where(fault_code: FAULT_CODE, resolved_at: nil)
      .update_all(resolved_at: @recorded_at, updated_at: Time.current)
  end
end
