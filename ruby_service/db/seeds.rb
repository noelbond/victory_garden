# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Sample crop profiles (hardcoded)
tomato = CropProfile.find_or_create_by!(crop_id: "tomato") do |crop|
  crop.crop_name = "Tomato"
  crop.dry_threshold = 30.0
  crop.runtime_seconds = 45
  crop.max_daily_runtime_seconds = 300
  crop.climate_preference = "Warm, sunny"
  crop.time_to_harvest_days = 75
end

basil = CropProfile.find_or_create_by!(crop_id: "basil") do |crop|
  crop.crop_name = "Basil"
  crop.dry_threshold = 35.0
  crop.runtime_seconds = 30
  crop.max_daily_runtime_seconds = 240
  crop.climate_preference = "Warm, humid"
  crop.time_to_harvest_days = 50
end

Zone.find_or_create_by!(zone_id: "zone1") do |zone|
  zone.name = "Greenhouse Zone 1"
  zone.node_id = "sensor-gh1-zone1"
  zone.crop_profile = tomato
  zone.active = true
  zone.allowed_hours = { "start_hour" => 6, "end_hour" => 20 }
end

Zone.find_or_create_by!(zone_id: "zone2") do |zone|
  zone.name = "Greenhouse Zone 2"
  zone.node_id = "sensor-gh1-zone2"
  zone.crop_profile = basil
  zone.active = true
  zone.allowed_hours = { "start_hour" => 6, "end_hour" => 20 }
end

ConnectionSetting.find_or_create_by!(mqtt_host: "localhost") do |s|
  s.mqtt_port = 1883
  s.readings_topic = "watering/readings"
  s.actuators_topic = "watering/actuators"
  s.command_topic = "watering/commands"
  s.config_topic = "watering/config"
  s.bluetooth_enabled = false
  s.notes = "Default local broker"
end
