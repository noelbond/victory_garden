class WateringCommand
  Result = Struct.new(:event, :payload, keyword_init: true)

  def self.start(_zone)
    raise ArgumentError, "start_watering requires a configured node"
  end

  def self.start_node(node)
    unless node.watering_configured?
      raise ArgumentError, "node must have an active assigned zone, crop profile, and irrigation line before watering"
    end

    unless node.irrigation_line_supported?
      raise ArgumentError, "node irrigation line is not supported by installed actuator capacity"
    end

    profile = node.crop_profile

    new(
      node.zone,
      node: node,
      command: "start_watering",
      runtime_seconds: profile.max_pulse_runtime_sec,
      reason: "manual_trigger"
    ).issue!
  end

  def self.stop(_zone)
    raise ArgumentError, "zone-level stop_watering is unavailable until stop_all is implemented"
  end

  def initialize(zone, node: nil, command:, runtime_seconds:, reason:)
    @zone = zone
    @node = node
    @command = command
    @runtime_seconds = runtime_seconds
    @reason = reason
  end

  def issue!
    issued_at = Time.current
    actuator_issued_at = issued_at.utc.iso8601
    payload = {
      command: @command,
      zone_id: @zone.zone_id,
      node_id: @node&.node_id,
      runtime_seconds: @runtime_seconds,
      reason: @reason,
      issued_at: actuator_issued_at,
      idempotency_key: "#{@node&.node_id || @zone.zone_id}-#{issued_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
    }

    event = WateringEvent.create!(
      zone: @zone,
      node_id: payload[:node_id],
      command: payload[:command],
      runtime_seconds: payload[:runtime_seconds],
      reason: payload[:reason],
      issued_at: issued_at,
      idempotency_key: payload[:idempotency_key],
      status: "queued"
    )

    # Scheduled independently of CommandPublishJob's own success (even after
    # that job's own retries are exhausted) so a publish failure still
    # surfaces as a visible ACTUATOR_TIMEOUT fault instead of leaving this
    # event stuck "queued" forever.
    ActuatorCommandTimeoutJob
      .set(wait: timeout_window.seconds)
      .perform_later(idempotency_key: payload[:idempotency_key], timeout_seconds: timeout_window)

    CommandPublishJob.perform_later(payload)
    Result.new(event: event, payload: payload)
  end

  private

  def timeout_window
    return 30 unless @runtime_seconds.to_i.positive?

    [@runtime_seconds.to_i + 30, 60].max
  end
end
