tomato = CropProfile.find_or_create_by!(crop_id: "tomato") do |crop|
  crop.crop_name = "Tomato"
  crop.dry_threshold = 30.0
  crop.max_pulse_runtime_sec = 45
  crop.daily_max_runtime_sec = 300
  crop.climate_preference = "Warm, sunny"
  crop.time_to_harvest_days = 75
end

basil = CropProfile.find_or_create_by!(crop_id: "basil") do |crop|
  crop.crop_name = "Basil"
  crop.dry_threshold = 40.0
  crop.max_pulse_runtime_sec = 30
  crop.daily_max_runtime_sec = 240
  crop.climate_preference = "Warm, humid"
  crop.time_to_harvest_days = 50
end

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
  s.readings_topic = "greenhouse/zones/+/state"
  s.actuators_topic = "greenhouse/zones/+/actuator/status"
  s.command_topic = "greenhouse/zones/{zone_id}/actuator/command"
  s.config_topic = "greenhouse/system/config/current"
  s.bluetooth_enabled = false
  s.notes = "Default local broker"
end
