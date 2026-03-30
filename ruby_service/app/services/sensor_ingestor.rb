class SensorIngestor
  def initialize(payload)
    @payload = PayloadContracts::NodeState.normalize!(payload)
  end

  def call
    node = upsert_node!
    zone = resolve_zone_for(node)

    if zone.nil?
      Rails.logger.warn(
        "SensorIngestor: no zone found for node #{@payload['node_id']} " \
        "(reported_zone_id=#{@payload['zone_id'].inspect}). Skipping decision."
      )
      return node
    end

    reading = SensorReading.create!(
      zone: zone,
      node_id: @payload.fetch("node_id"),
      recorded_at: @payload.fetch("recorded_at"),
      schema_version: @payload["schema_version"],
      moisture_raw: @payload.fetch("moisture_raw"),
      moisture_percent: @payload["moisture_percent"],
      soil_temp_c: @payload["soil_temp_c"],
      battery_voltage: @payload["battery_voltage"],
      battery_percent: @payload["battery_percent"],
      wifi_rssi: @payload["wifi_rssi"],
      uptime_seconds: @payload["uptime_seconds"],
      wake_count: @payload["wake_count"],
      ip_address: @payload["ip"],
      health: @payload["health"],
      last_error: @payload["last_error"],
      publish_reason: @payload["publish_reason"],
      raw_payload: @payload
    )

    zone.with_lock do
      command = DecisionService.new(zone: zone, reading: reading).call
      next nil unless command

      event = WateringEvent.create!(
        zone: zone,
        command: command[:command],
        runtime_seconds: command[:runtime_seconds],
        reason: command[:reason],
        issued_at: command[:issued_at],
        idempotency_key: command[:idempotency_key],
        status: "queued"
      )

      CommandPublishJob.perform_later(command)
      event
    end
  end

  private

  def upsert_node!
    node = Node.find_or_initialize_by(node_id: @payload.fetch("node_id"))
    node.assign_attributes(
      reported_zone_id: @payload["zone_id"],
      last_seen_at: @payload.fetch("recorded_at"),
      schema_version: @payload["schema_version"],
      provisioned: true,
      battery_voltage: @payload["battery_voltage"],
      wifi_rssi: @payload["wifi_rssi"],
      health: @payload["health"],
      last_error: @payload["last_error"]
    )
    node.save!
    node
  end

  def resolve_zone_for(node)
    # The DB assignment (node.zone) is the authoritative zone for a node.
    # reported_zone_id in the payload is advisory/diagnostic only — a node
    # must be explicitly claimed in the UI before it can trigger decisions.
    node.zone
  end
end
