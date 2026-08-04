class ConfigPublishJob < ApplicationJob
  queue_as :default

  # This is a fleet-wide broadcast (every node's zone/crop/watering config),
  # not scoped to one zone -- a failure here silently leaves every node
  # running stale config with no visible signal otherwise. The block form of
  # retry_on runs once retries are truly exhausted (not on every individual
  # attempt), so this creates one fault per genuine outage, not one per retry.
  # MQTT::Exception is caught explicitly alongside StandardError because the
  # mqtt gem's exceptions (ProtocolException, NotConnectedException, etc.)
  # inherit from Ruby's root Exception, not StandardError -- retry_on alone
  # would silently never catch a genuine MQTT protocol/connection failure.
  retry_on StandardError, MQTT::Exception, attempts: 3, wait: 5.seconds do |_job, error|
    Fault.create!(
      zone: nil,
      fault_code: "CONFIG_PUBLISH_FAILED",
      detail: "System-wide config publish failed after 3 attempts: #{error.class}: #{error.message}",
      recorded_at: Time.current
    )
  end

  def perform
    zones = Zone.where(active: true).includes(:crop_profile, :nodes).order(:zone_id)
    control_nodes = Node.assigned.includes(:crop_profile, zone: :crop_profile).where.not(irrigation_line: nil).order(:irrigation_line, :node_id)
    assigned_lines = Zone.where.not(irrigation_line: nil).order(:irrigation_line, :zone_id)
    crop_ids = (zones.map(&:crop_profile_id) + control_nodes.map { |node| node.effective_crop_profile&.id }).compact.uniq
    crops = CropProfile.where(id: crop_ids).or(CropProfile.where(active: true)).distinct.order(:crop_id)
    payload = {
      crops: crops.map { |c| crop_payload(c) },
      zones: zones.map { |z| zone_payload(z) },
      nodes: control_nodes.select(&:watering_configured?).map { |node| node_payload(node) },
      watering_mode: "node"
    }
    MqttClient.publish_config(payload)
    MqttClient.publish_actuator_config(
      schema_version: "actuator-config/v1",
      config_version: Time.current.utc.iso8601,
      irrigation_line_count: ConnectionSetting.first&.irrigation_line_count.to_i,
      zones: assigned_lines.map { |z| actuator_zone_payload(z) },
      nodes: control_nodes.select(&:watering_configured?).map { |node| actuator_node_payload(node) }
    )
    nodes_by_device = Node.group_by_device(Node.where.not(zone_id: nil).order(:node_id))
    nodes_by_device.each_value do |nodes|
      PublishNodeConfigJob.perform_later(nodes.first.id)
    end
  end

  private

  def crop_payload(crop)
    {
      crop_id: crop.crop_id,
      crop_name: crop.crop_name,
      dry_threshold: crop.dry_threshold.to_f,
      max_pulse_runtime_sec: crop.max_pulse_runtime_sec,
      daily_max_runtime_sec: crop.daily_max_runtime_sec,
      climate_preference: crop.climate_preference,
      time_to_harvest_days: crop.time_to_harvest_days
    }
  end

  def zone_payload(zone)
    {
      zone_id: zone.zone_id,
      crop_id: zone.crop_profile.crop_id,
      node_ids: zone.nodes.sort_by(&:node_id).map(&:node_id),
      active: zone.active,
      allowed_hours: zone.allowed_hours,
      irrigation_line: zone.irrigation_line,
      watering_mode: "node"
    }
  end

  def node_payload(node)
    crop = node.effective_crop_profile
    {
      node_id: node.node_id,
      zone_id: node.zone.zone_id,
      crop_id: crop.crop_id,
      active: node.zone.active,
      allowed_hours: node.zone.allowed_hours,
      irrigation_line: node.irrigation_line
    }
  end

  def actuator_zone_payload(zone)
    {
      zone_id: zone.zone_id,
      irrigation_line: zone.irrigation_line,
      active: zone.active
    }
  end

  def actuator_node_payload(node)
    {
      node_id: node.node_id,
      zone_id: node.zone.zone_id,
      irrigation_line: node.irrigation_line,
      active: node.zone.active
    }
  end
end
