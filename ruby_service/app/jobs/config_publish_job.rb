class ConfigPublishJob < ApplicationJob
  queue_as :default

  def perform
    crops = CropProfile.where(active: true)
    zones = Zone.where(active: true).includes(:crop_profile)
    payload = {
      crops: crops.map { |c| crop_payload(c) },
      zones: zones.map { |z| zone_payload(z) }
    }
    MqttClient.publish_config(payload)
  end

  private

  def crop_payload(crop)
    {
      crop_id: crop.crop_id,
      crop_name: crop.crop_name,
      dry_threshold: crop.dry_threshold.to_f,
      runtime_seconds: crop.runtime_seconds,
      max_daily_runtime_seconds: crop.max_daily_runtime_seconds,
      active: crop.active
    }
  end

  def zone_payload(zone)
    {
      zone_id: zone.zone_id,
      crop_id: zone.crop_profile.crop_id,
      node_id: zone.node_id,
      active: zone.active,
      allowed_hours: zone.allowed_hours
    }
  end
end
