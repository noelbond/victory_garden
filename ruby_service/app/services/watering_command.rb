class WateringCommand
  Result = Struct.new(:event, :payload, keyword_init: true)

  def self.start(zone)
    new(zone, command: "start_watering", runtime_seconds: zone.crop_profile.max_pulse_runtime_sec, reason: "manual_trigger").issue!
  end

  def self.start_node(node)
    profile = node.effective_crop_profile
    raise ArgumentError, "node must have a crop profile before watering" if profile.blank?

    new(
      node.zone,
      node: node,
      command: "start_watering",
      runtime_seconds: profile.max_pulse_runtime_sec,
      reason: "manual_trigger"
    ).issue!
  end

  def self.start_setup_validation(zone, node: nil, enqueue: true)
    if node.present?
      profile = node.effective_crop_profile
      raise ArgumentError, "node must have a crop profile before watering" if profile.blank?

      runtime_seconds = profile.max_pulse_runtime_sec
    else
      runtime_seconds = zone.crop_profile.max_pulse_runtime_sec
    end

    new(
      zone,
      node: node,
      command: "start_watering",
      runtime_seconds: runtime_seconds,
      reason: "setup_validation",
      event_attributes: WateringEvent.setup_target_attributes(
        zone: zone,
        node: node,
        runtime_seconds: runtime_seconds
      ).merge(
        setup_validation: true,
        setup_current: true
      )
    ).issue!(enqueue: enqueue)
  end

  def self.stop(zone)
    new(zone, command: "stop_watering", runtime_seconds: nil, reason: "manual_stop").issue!
  end

  def initialize(zone, node: nil, command:, runtime_seconds:, reason:, event_attributes: {})
    @zone = zone
    @node = node
    @command = command
    @runtime_seconds = runtime_seconds
    @reason = reason
    @event_attributes = event_attributes
  end

  def issue!(enqueue: true)
    issued_at = Time.current
    payload = {
      command: @command,
      zone_id: @zone.zone_id,
      node_id: @node&.node_id,
      runtime_seconds: @runtime_seconds,
      reason: @reason,
      issued_at: issued_at,
      idempotency_key: "#{@node&.node_id || @zone.zone_id}-#{issued_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
    }

    event = WateringEvent.create!({
      zone: @zone,
      node_id: payload[:node_id],
      command: payload[:command],
      runtime_seconds: payload[:runtime_seconds],
      reason: payload[:reason],
      issued_at: payload[:issued_at],
      idempotency_key: payload[:idempotency_key],
      status: "queued"
    }.merge(@event_attributes))

    CommandPublishJob.perform_later(payload) if enqueue
    Result.new(event: event, payload: payload)
  end
end
