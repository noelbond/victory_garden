class WateringPolicy
  def initialize(zone:, now: Time.current)
    @zone = zone
    @now = now
  end

  def allowed_now?
    return true if @zone.allowed_hours.blank?

    start_hour = @zone.allowed_hours["start_hour"]
    end_hour = @zone.allowed_hours["end_hour"]
    return true if start_hour.nil? || end_hour.nil?

    hour = @now.in_time_zone.hour
    if start_hour <= end_hour
      hour >= start_hour && hour < end_hour
    else
      hour >= start_hour || hour < end_hour
    end
  end
end
