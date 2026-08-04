class PublishNodeConfigJob < ApplicationJob
  queue_as :default
  # MQTT::Exception is caught explicitly alongside StandardError because the
  # mqtt gem's exceptions inherit from Ruby's root Exception, not
  # StandardError -- retry_on alone would silently never catch a genuine
  # MQTT protocol/connection failure. Pre-existing gap (not introduced
  # today), found while adding the same retry_on pattern elsewhere.
  retry_on StandardError, MQTT::Exception, attempts: 3, wait: 5.seconds

  def self.current_utc_offset_hours
    Time.now.getlocal.utc_offset / 3600
  end

  def perform(node_id)
    node = Node.includes(zone: :crop_profile).find(node_id)
    device_id = node.device_id.presence || node.node_id
    siblings = node.device_siblings.includes(zone: :crop_profile).order(:node_id).to_a
    payload = build_payload(node, siblings: siblings, device_id: device_id)
    published_at = Time.current

    Node.where(id: siblings.map(&:id)).update_all(
      desired_config: payload,
      config_version: payload[:config_version],
      config_status: node.assigned? ? "pending" : "unassigned",
      config_published_at: published_at,
      config_error: nil,
      updated_at: published_at
    )

    MqttClient.publish_node_config(node_id: device_id, payload: payload)
  rescue StandardError, MQTT::Exception => e
    error_node_ids = siblings.present? ? siblings.map(&:id) : Array(node&.id)
    Node.where(id: error_node_ids).update_all(
      config_status: "error",
      config_error: e.message,
      updated_at: Time.current
    )
    raise
  end

  private

  def build_payload(node, siblings:, device_id:)
    issued_at = Time.current.utc.iso8601

    if node.zone.present?
      crop = node.effective_crop_profile
      payload = {
        schema_version: "node-config/v1",
        config_version: issued_at,
        issued_at: issued_at,
        node_id: device_id,
        assigned: true,
        utc_offset_hours: current_utc_offset_hours,
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
        }
      }

      if node.device_id.present?
        payload[:channels] = siblings.map { |sibling| channel_payload(sibling) }
      else
        payload[:sensor] = calibration_payload(node)
      end
      payload
    else
      {
        schema_version: "node-config/v1",
        config_version: issued_at,
        issued_at: issued_at,
        node_id: device_id,
        assigned: false,
        utc_offset_hours: current_utc_offset_hours,
        zone: nil,
        crop: nil,
        channels: node.device_id.present? ? siblings.map { |sibling| channel_payload(sibling) } : nil
      }.compact
    end
  end

  def channel_payload(node)
    { node_id: node.node_id }.merge(calibration_payload(node))
  end

  def calibration_payload(node)
    return {} unless node.calibration_configured?

    {
      moisture_raw_dry: node.moisture_raw_dry,
      moisture_raw_wet: node.moisture_raw_wet
    }
  end

  def current_utc_offset_hours
    self.class.current_utc_offset_hours
  end
end
