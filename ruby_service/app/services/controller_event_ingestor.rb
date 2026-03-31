class ControllerEventIngestor
  def initialize(payload)
    @payload = payload
  end

  def call
    return nil unless @payload["action"] == "water"
    return nil if @payload["idempotency_key"].blank?

    zone = Zone.find_by(zone_id: @payload.fetch("zone_id"))
    raise ArgumentError, "Unknown zone_id: #{@payload['zone_id']}" unless zone
    runtime_seconds = normalized_runtime_seconds!

    WateringEvent.create_or_find_by!(idempotency_key: @payload["idempotency_key"]) do |event|
      event.zone = zone
      event.command = "start_watering"
      event.runtime_seconds = runtime_seconds
      event.reason = @payload["reason"].presence || "below_dry_threshold"
      event.issued_at = @payload.fetch("timestamp")
      event.status = "queued"
    end
  end

  private

  def normalized_runtime_seconds!
    runtime_seconds = Integer(@payload["runtime_seconds"])
    return runtime_seconds if runtime_seconds.positive?

    raise ArgumentError, "Invalid runtime_seconds: #{@payload['runtime_seconds'].inspect}"
  rescue ArgumentError, TypeError
    raise ArgumentError, "Invalid runtime_seconds: #{@payload['runtime_seconds'].inspect}"
  end
end
