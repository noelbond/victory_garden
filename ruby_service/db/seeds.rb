starter_crops = [
  {
    crop_id: "tomato",
    crop_name: "Tomato",
    dry_threshold: 30.0,
    max_pulse_runtime_sec: 45,
    daily_max_runtime_sec: 300,
    climate_preference: "Warm, sunny",
    time_to_harvest_days: 75
  },
  {
    crop_id: "basil",
    crop_name: "Basil",
    dry_threshold: 40.0,
    max_pulse_runtime_sec: 30,
    daily_max_runtime_sec: 240,
    climate_preference: "Warm, humid",
    time_to_harvest_days: 50
  },
  {
    crop_id: "squash",
    crop_name: "Squash",
    dry_threshold: 35.0,
    max_pulse_runtime_sec: 45,
    daily_max_runtime_sec: 300,
    climate_preference: "Warm, steady moisture",
    time_to_harvest_days: 55
  },
  {
    crop_id: "pepper",
    crop_name: "Pepper",
    dry_threshold: 30.0,
    max_pulse_runtime_sec: 40,
    daily_max_runtime_sec: 260,
    climate_preference: "Warm, slightly drier between watering",
    time_to_harvest_days: 70
  },
  {
    crop_id: "lettuce",
    crop_name: "Lettuce",
    dry_threshold: 45.0,
    max_pulse_runtime_sec: 25,
    daily_max_runtime_sec: 220,
    climate_preference: "Cool, evenly moist",
    time_to_harvest_days: 35
  },
  {
    crop_id: "herbs",
    crop_name: "Mixed Herbs",
    dry_threshold: 35.0,
    max_pulse_runtime_sec: 25,
    daily_max_runtime_sec: 180,
    climate_preference: "Bright, moderate moisture",
    time_to_harvest_days: 45
  }
]

starter_crops.each do |attributes|
  CropProfile.find_or_initialize_by(crop_id: attributes.fetch(:crop_id)).tap do |crop|
    crop.assign_attributes(attributes)
    crop.save!
  end
end

tomato = CropProfile.find_by!(crop_id: "tomato")
basil = CropProfile.find_by!(crop_id: "basil")

Zone.find_or_create_by!(zone_id: "zone1") do |zone|
  zone.name = "Greenhouse Zone 1"
  zone.crop_profile = tomato
  zone.active = true
  zone.allowed_hours = { "start_hour" => 6, "end_hour" => 20 }
end

Zone.find_or_create_by!(zone_id: "zone2") do |zone|
  zone.name = "Greenhouse Zone 2"
  zone.crop_profile = basil
  zone.active = true
  zone.allowed_hours = { "start_hour" => 6, "end_hour" => 20 }
end

ConnectionSetting.find_or_create_by!(mqtt_host: "localhost") do |s|
  s.mqtt_port = 1883
  s.readings_topic = "greenhouse/zones/+/nodes/+/state"
  s.actuators_topic = "greenhouse/zones/+/actuator/status"
  s.command_topic = "greenhouse/zones/{zone_id}/actuator/command"
  s.config_topic = "greenhouse/system/config/current"
  s.bluetooth_enabled = false
  s.notes = "Default local broker"
end
