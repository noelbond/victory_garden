class WateringCommand
  Result = Struct.new(:event, :payload, keyword_init: true)

  def self.start(zone)
    new(zone, command: "start_watering", runtime_seconds: zone.crop_profile.max_pulse_runtime_sec, reason: "manual_trigger").issue!
  end

  def self.stop(zone)
    new(zone, command: "stop_watering", runtime_seconds: nil, reason: "manual_stop").issue!
  end

  def initialize(zone, command:, runtime_seconds:, reason:)
    @zone = zone
    @command = command
    @runtime_seconds = runtime_seconds
    @reason = reason
  end

  def issue!
    issued_at = Time.current
    payload = {
      command: @command,
      zone_id: @zone.zone_id,
      runtime_seconds: @runtime_seconds,
      reason: @reason,
      issued_at: issued_at,
      idempotency_key: "#{@zone.zone_id}-#{issued_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
    }

    event = WateringEvent.create!(
      zone: @zone,
      command: payload[:command],
      runtime_seconds: payload[:runtime_seconds],
      reason: payload[:reason],
      issued_at: payload[:issued_at],
      idempotency_key: payload[:idempotency_key],
      status: "queued"
    )

    CommandPublishJob.perform_later(payload)
    Result.new(event: event, payload: payload)
  end
end
