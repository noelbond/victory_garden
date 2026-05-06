class PublishNodeConfigJob < ApplicationJob
  queue_as :default
  retry_on StandardError, attempts: 3, wait: 5.seconds

  def perform(node_id)
    node = Node.includes(zone: :crop_profile).find(node_id)
    payload = build_payload(node)

    node.update!(
      desired_config: payload,
      config_version: payload[:config_version],
      config_status: node.claimed? ? "pending" : "unassigned",
      config_published_at: Time.current,
      config_error: nil
    )

    MqttClient.publish_node_config(node_id: node.node_id, payload: payload)
  rescue StandardError => e
    node&.update!(config_status: "error", config_error: e.message)
    raise
  end

  private

  def build_payload(node)
    issued_at = Time.current.utc.iso8601

    if node.zone.present?
      crop = node.zone.crop_profile
      sensor_payload = {}
      sensor_payload[:moisture_raw_dry] = node.moisture_raw_dry if node.moisture_raw_dry.present?
      sensor_payload[:moisture_raw_wet] = node.moisture_raw_wet if node.moisture_raw_wet.present?

      {
        schema_version: "node-config/v1",
        config_version: issued_at,
        issued_at: issued_at,
        node_id: node.node_id,
        assigned: true,
        zone: {
          zone_id: node.zone.zone_id,
          active: node.zone.active,
          allowed_hours: node.zone.allowed_hours,
          publish_interval_ms: node.zone.publish_interval_ms
        },
        crop: {
          crop_id: crop.crop_id,
          crop_name: crop.crop_name,
          dry_threshold: crop.dry_threshold.to_f,
          max_pulse_runtime_sec: crop.max_pulse_runtime_sec,
          daily_max_runtime_sec: crop.daily_max_runtime_sec,
          climate_preference: crop.climate_preference,
          time_to_harvest_days: crop.time_to_harvest_days
        },
        sensor: sensor_payload
      }
    else
      {
        schema_version: "node-config/v1",
        config_version: issued_at,
        issued_at: issued_at,
        node_id: node.node_id,
        assigned: false,
        zone: nil,
        crop: nil
      }
    end
  end
end
