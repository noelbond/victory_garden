class SensorIngestor
  def initialize(payload)
    @payload = PayloadContracts::NodeState.normalize!(payload)
  end

  def call
    node = upsert_node!
    enqueue_config_refresh_if_utc_offset_changed(node)
    zone = resolve_zone_for(node)

    if zone.nil?
      Rails.logger.warn(
        "SensorIngestor: no zone found for node #{@payload['node_id']} " \
        "(reported_zone_id=#{@payload['zone_id'].inspect}). Skipping decision."
      )
      return node
    end

    existing_reading = SensorReading.find_by(
      node_id: @payload.fetch("node_id"),
      recorded_at: @payload.fetch("recorded_at")
    )
    return existing_reading if existing_reading

    temperature_alert = GreenhouseTemperatureAlert.new(
      zone: zone,
      temperature_c: @payload["air_temperature_c"],
      recorded_at: @payload.fetch("recorded_at")
    )
    alert_status = temperature_alert.status

    reading = SensorReading.create!(
      zone: zone,
      node_id: @payload.fetch("node_id"),
      recorded_at: @payload.fetch("recorded_at"),
      schema_version: @payload["schema_version"],
      moisture_raw: @payload["moisture_raw"],
      moisture_percent: @payload["moisture_percent"],
      air_temperature_c: @payload["air_temperature_c"],
      humidity_percent: @payload["humidity_percent"],
      soil_moisture_read: @payload["soil_moisture_read"] == true,
      greenhouse_alert_status: alert_status,
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

    temperature_alert.record!(status: alert_status) if @payload["air_temperature_c"].present?
    acknowledge_correlated_command!

    reading
  end

  private

  def upsert_node!
    node = Node.find_or_initialize_by(node_id: @payload.fetch("node_id"))
    attributes = {
      reported_zone_id: @payload["zone_id"],
      last_seen_at: [node.last_seen_at, @payload.fetch("recorded_at")].compact.max,
      schema_version: @payload["schema_version"],
      provisioned: true,
      battery_voltage: @payload["battery_voltage"],
      wifi_rssi: @payload["wifi_rssi"],
      health: @payload["health"],
      last_error: @payload["last_error"]
    }
    attributes[:device_id] = @payload["device_id"] if @payload.key?("device_id")
    node.assign_attributes(attributes)
    node.save!
    node
  end

  def resolve_zone_for(node)
    # The DB assignment (node.zone) is the authoritative zone for a node.
    # reported_zone_id in the payload is advisory/diagnostic only — a node
    # must be explicitly assigned in the UI before it can trigger decisions.
    node.zone
  end

  def enqueue_config_refresh_if_utc_offset_changed(node)
    desired_config = node.desired_config
    return unless desired_config.is_a?(Hash)

    desired_offset = desired_config["utc_offset_hours"] || desired_config[:utc_offset_hours]
    return if desired_offset.nil?
    return if desired_offset.to_i == PublishNodeConfigJob.current_utc_offset_hours

    PublishNodeConfigJob.perform_later(node.id)
  end

  def acknowledge_correlated_command!
    command_message_id = @payload["command_message_id"]
    return if command_message_id.blank?

    command = NodeCommand.find_by(command_id: command_message_id)
    return if command.nil?
    return if NodeCommand::TERMINAL_STATUSES.include?(command.status)

    command.update!(status: "acknowledged", acknowledged_at: Time.current)
  end
end
