class SensorIngestor
  def initialize(payload)
    @payload = payload
  end

  def call
    zone = Zone.find_by(zone_id: @payload.fetch("zone_id"))
    raise ArgumentError, "Unknown zone_id: #{@payload['zone_id']}" unless zone

    reading = SensorReading.create!(
      zone: zone,
      node_id: @payload.fetch("node_id"),
      recorded_at: @payload.fetch("timestamp"),
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

    command = DecisionService.new(zone: zone, reading: reading).call
    return nil unless command

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
