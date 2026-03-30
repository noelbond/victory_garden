class ConfigPublishJob < ApplicationJob
  queue_as :default

  def perform
    crops = CropProfile.where(active: true)
    zones = Zone.where(active: true).includes(:crop_profile, :nodes)
    payload = {
      crops: crops.map { |c| crop_payload(c) },
      zones: zones.map { |z| zone_payload(z) }
    }
    MqttClient.publish_config(payload)
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
      time_to_harvest_days: crop.time_to_harvest_days,
      active: crop.active
    }
  end

  def zone_payload(zone)
    {
      zone_id: zone.zone_id,
      crop_id: zone.crop_profile.crop_id,
      node_ids: zone.nodes.sort_by(&:node_id).map(&:node_id),
      active: zone.active,
      allowed_hours: zone.allowed_hours
    }
  end
end
