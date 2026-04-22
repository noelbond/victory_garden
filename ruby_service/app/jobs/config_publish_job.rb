class ConfigPublishJob < ApplicationJob
  queue_as :default

  def perform
    zones = Zone.where(active: true).includes(:crop_profile, :nodes).order(:zone_id)
    assigned_lines = Zone.where.not(irrigation_line: nil).order(:irrigation_line, :zone_id)
    crop_ids = zones.map(&:crop_profile_id).uniq
    crops = CropProfile.where(id: crop_ids).or(CropProfile.where(active: true)).distinct.order(:crop_id)
    payload = {
      crops: crops.map { |c| crop_payload(c) },
      zones: zones.map { |z| zone_payload(z) }
    }
    MqttClient.publish_config(payload)
    MqttClient.publish_actuator_config(
      schema_version: "actuator-config/v1",
      config_version: Time.current.utc.iso8601,
      irrigation_line_count: ConnectionSetting.first&.irrigation_line_count.to_i,
      zones: assigned_lines.map { |z| actuator_zone_payload(z) }
    )
    Node.where.not(zone_id: nil).find_each do |node|
      PublishNodeConfigJob.perform_later(node.id)
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
      irrigation_line: zone.irrigation_line
    }
  end

  def actuator_zone_payload(zone)
    {
      zone_id: zone.zone_id,
      irrigation_line: zone.irrigation_line,
      active: zone.active
    }
  end
end
