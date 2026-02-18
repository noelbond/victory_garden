class DecisionService
  def initialize(zone:, reading:)
    @zone = zone
    @reading = reading
  end

  def call
    return nil if @reading.moisture_percent.nil?
    return nil unless WateringPolicy.new(zone: @zone, now: @reading.recorded_at).allowed_now?

    profile = @zone.crop_profile
    return nil if @reading.moisture_percent >= profile.dry_threshold

    remaining = profile.max_daily_runtime_seconds - runtime_today
    return nil if remaining <= 0

    runtime = [profile.runtime_seconds, remaining].min
    {
      command: "start_watering",
      zone_id: @zone.zone_id,
      runtime_seconds: runtime,
      reason: "below_dry_threshold",
      issued_at: @reading.recorded_at,
      idempotency_key: build_idempotency_key(@reading.recorded_at)
    }
  end

  private

  def runtime_today
    start_time = @reading.recorded_at.beginning_of_day
    end_time = @reading.recorded_at.end_of_day
    WateringEvent.where(zone: @zone, command: "start_watering", issued_at: start_time..end_time).sum(:runtime_seconds)
  end

  def build_idempotency_key(time)
    "#{@zone.zone_id}-#{time.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
  end
end
