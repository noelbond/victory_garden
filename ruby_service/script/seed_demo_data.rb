unless Rails.env.development? || Rails.env.test? || ENV["ALLOW_DEMO_SEED"] == "1"
  abort <<~MESSAGE
    seed_demo_data.rb only runs in development or test by default.

    It overwrites demo connection settings, demo zones, demo crop profiles, and demo readings.
    If you intentionally need to run it elsewhere, re-run with ALLOW_DEMO_SEED=1.
  MESSAGE
end

now = Time.current.change(sec: 0)

def upsert_crop(crop_id:, crop_name:, dry_threshold:, max_pulse_runtime_sec:, daily_max_runtime_sec:, climate_preference:, time_to_harvest_days:)
  crop = CropProfile.find_or_initialize_by(crop_id: crop_id)
  crop.assign_attributes(
    crop_name: crop_name,
    dry_threshold: dry_threshold,
    max_pulse_runtime_sec: max_pulse_runtime_sec,
    daily_max_runtime_sec: daily_max_runtime_sec,
    climate_preference: climate_preference,
    time_to_harvest_days: time_to_harvest_days,
    active: true
  )
  crop.save!
  crop
end

def upsert_zone(zone_id:, name:, crop_profile:, irrigation_line:, publish_interval_ms:)
  zone = Zone.find_or_initialize_by(zone_id: zone_id)
  zone.assign_attributes(
    name: name,
    crop_profile: crop_profile,
    active: true,
    irrigation_line: irrigation_line,
    publish_interval_ms: publish_interval_ms,
    allowed_hours: { "start_hour" => 6, "end_hour" => 20 }
  )
  zone.save!
  zone
end

def upsert_node(node_id:, zone:, last_seen_at:, reported_zone_id:, health:, wifi_rssi:, battery_voltage:, last_error:, config_status:, config_version:, moisture_raw_dry:, moisture_raw_wet:, provisioned: true)
  node = Node.find_or_initialize_by(node_id: node_id)
  node.assign_attributes(
    zone: zone,
    reported_zone_id: reported_zone_id,
    last_seen_at: last_seen_at,
    provisioned: provisioned,
    health: health,
    wifi_rssi: wifi_rssi,
    battery_voltage: battery_voltage,
    last_error: last_error,
    config_status: config_status,
    config_version: config_version,
    config_published_at: last_seen_at - 5.minutes,
    config_acknowledged_at: last_seen_at - 4.minutes,
    moisture_raw_dry: moisture_raw_dry,
    moisture_raw_wet: moisture_raw_wet
  )
  node.save!
  node
end

def recreate_sensor_readings!(node:, rows:)
  SensorReading.where(node_id: node.node_id).delete_all

  rows.each do |row|
    SensorReading.create!(
      zone: node.zone,
      node_id: node.node_id,
      recorded_at: row.fetch(:recorded_at),
      schema_version: "node-state/v1",
      moisture_raw: row.fetch(:moisture_raw),
      moisture_percent: row.fetch(:moisture_percent),
      battery_voltage: row.fetch(:battery_voltage),
      battery_percent: row.fetch(:battery_percent),
      wifi_rssi: row.fetch(:wifi_rssi),
      soil_temp_c: row.fetch(:soil_temp_c),
      uptime_seconds: row.fetch(:uptime_seconds),
      wake_count: row.fetch(:wake_count),
      ip_address: row.fetch(:ip_address),
      health: row.fetch(:health),
      last_error: row.fetch(:last_error),
      publish_reason: row.fetch(:publish_reason),
      raw_payload: {
        "schema_version" => "node-state/v1",
        "node_id" => node.node_id,
        "zone_id" => node.zone.zone_id,
        "demo" => true
      }
    )
  end

  latest = rows.max_by { |row| row.fetch(:recorded_at) }
  node.update!(
    last_seen_at: latest.fetch(:recorded_at),
    reported_zone_id: node.zone.zone_id,
    health: latest.fetch(:health),
    wifi_rssi: latest.fetch(:wifi_rssi),
    battery_voltage: latest.fetch(:battery_voltage),
    last_error: latest.fetch(:last_error)
  )
end

def recreate_watering_history!(zone:, completed_events:, fault_events: [])
  WateringEvent.where(zone: zone).where("idempotency_key LIKE ?", "demo-%").delete_all
  ActuatorStatus.where(zone: zone).where("idempotency_key LIKE ?", "demo-%").delete_all
  Fault.where(zone: zone).where("fault_code LIKE ?", "DEMO_%").delete_all

  completed_events.each do |row|
    idempotency_key = row.fetch(:idempotency_key)
    issued_at = row.fetch(:issued_at)
    runtime_seconds = row.fetch(:runtime_seconds)

    WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: runtime_seconds,
      reason: row.fetch(:reason),
      issued_at: issued_at,
      idempotency_key: idempotency_key,
      status: "completed"
    )

    ActuatorStatus.create!(
      zone: zone,
      state: "ACKNOWLEDGED",
      recorded_at: issued_at + 1.second,
      idempotency_key: idempotency_key
    )
    ActuatorStatus.create!(
      zone: zone,
      state: "RUNNING",
      recorded_at: issued_at + 2.seconds,
      idempotency_key: idempotency_key,
      actual_runtime_seconds: 0
    )
    ActuatorStatus.create!(
      zone: zone,
      state: "COMPLETED",
      recorded_at: issued_at + runtime_seconds.seconds,
      idempotency_key: idempotency_key,
      actual_runtime_seconds: runtime_seconds,
      flow_ml: row.fetch(:flow_ml, runtime_seconds * 3)
    )
  end

  fault_events.each do |row|
    idempotency_key = row.fetch(:idempotency_key)
    issued_at = row.fetch(:issued_at)

    WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: row.fetch(:runtime_seconds),
      reason: row.fetch(:reason),
      issued_at: issued_at,
      idempotency_key: idempotency_key,
      status: "fault"
    )

    ActuatorStatus.create!(
      zone: zone,
      state: "FAULT",
      recorded_at: issued_at + row.fetch(:fault_after_seconds, 9).seconds,
      idempotency_key: idempotency_key,
      actual_runtime_seconds: row.fetch(:actual_runtime_seconds, 8),
      fault_code: row.fetch(:fault_code),
      fault_detail: row.fetch(:fault_detail)
    )

    Fault.create!(
      zone: zone,
      fault_code: row.fetch(:fault_code),
      detail: row.fetch(:fault_detail),
      recorded_at: issued_at + row.fetch(:fault_after_seconds, 9).seconds,
      resolved_at: row[:resolved_at]
    )
  end
end

def build_demo_readings(node:, start_time:, count:, spacing_hours:, base_percent:, percent_step:, raw_dry:, raw_wet:, battery_voltage:, battery_percent:, ip_address:, health_pattern:, error_pattern:, reason_pattern:, temp_base:, rssi_base:)
  count.times.map do |index|
    recorded_at = start_time + (index * spacing_hours).hours
    moisture_percent = [[base_percent + (index % 5) * percent_step + (index / 5), 2].sum, 96].min.round(1)
    health = health_pattern.call(index, recorded_at)
    last_error = error_pattern.call(index, recorded_at)
    publish_reason = reason_pattern.call(index, recorded_at)
    moisture_raw = raw_dry + (((raw_wet - raw_dry) * moisture_percent) / 100.0).round

    {
      recorded_at: recorded_at,
      moisture_raw: moisture_raw,
      moisture_percent: moisture_percent,
      battery_voltage: (battery_voltage - (index * 0.01)).round(2),
      battery_percent: [battery_percent - index, 25].max,
      wifi_rssi: rssi_base - (index % 4),
      soil_temp_c: (temp_base + ((index % 3) * 0.6)).round(1),
      uptime_seconds: 800 + (index * 3600),
      wake_count: 120 + index,
      ip_address: ip_address,
      health: health,
      last_error: last_error,
      publish_reason: publish_reason
    }
  end
end

setting = ConnectionSetting.first_or_initialize
setting.assign_attributes(
  mqtt_host: "localhost",
  mqtt_port: 1883,
  mqtt_username: "admin",
  mqtt_password: "admin",
  irrigation_line_count: 3,
  readings_topic: "greenhouse/zones/+/nodes/+/state",
  actuators_topic: "greenhouse/zones/+/actuator/status",
  command_topic: "greenhouse/zones/{zone_id}/actuator/command",
  config_topic: "greenhouse/system/config/current",
  bluetooth_enabled: false,
  notes: "Local demo broker with rich reading history seed data"
)
setting.save!

tomato = upsert_crop(
  crop_id: "tomato",
  crop_name: "Tomato",
  dry_threshold: 30.0,
  max_pulse_runtime_sec: 45,
  daily_max_runtime_sec: 300,
  climate_preference: "Warm, sunny",
  time_to_harvest_days: 75
)

basil = upsert_crop(
  crop_id: "basil",
  crop_name: "Basil",
  dry_threshold: 40.0,
  max_pulse_runtime_sec: 30,
  daily_max_runtime_sec: 240,
  climate_preference: "Warm, humid",
  time_to_harvest_days: 50
)

pepper = upsert_crop(
  crop_id: "pepper",
  crop_name: "Pepper",
  dry_threshold: 35.0,
  max_pulse_runtime_sec: 40,
  daily_max_runtime_sec: 270,
  climate_preference: "Bright and warm",
  time_to_harvest_days: 85
)

zone1 = upsert_zone(
  zone_id: "zone1",
  name: "Greenhouse Zone 1",
  crop_profile: tomato,
  irrigation_line: 1,
  publish_interval_ms: 3_600_000
)

zone2 = upsert_zone(
  zone_id: "zone2",
  name: "Greenhouse Zone 2",
  crop_profile: basil,
  irrigation_line: 2,
  publish_interval_ms: 7_200_000
)

zone3 = upsert_zone(
  zone_id: "zone3",
  name: "Greenhouse Zone 3",
  crop_profile: pepper,
  irrigation_line: 3,
  publish_interval_ms: 14_400_000
)

zones_with_nodes = {
  zone1 => ("a".."h").map.with_index do |suffix, index|
    upsert_node(
      node_id: "demo-zone1-#{suffix}",
      zone: zone1,
      last_seen_at: now - (index + 1).minutes,
      reported_zone_id: zone1.zone_id,
      health: index == 6 ? "degraded" : "ok",
      wifi_rssi: -54 - index,
      battery_voltage: 4.1 - (index * 0.03),
      last_error: index == 6 ? "sensor glitch" : "none",
      config_status: "applied",
      config_version: now.iso8601,
      moisture_raw_dry: 512,
      moisture_raw_wet: 615
    )
  end,
  zone2 => (1..3).map do |index|
    upsert_node(
      node_id: "demo-zone2-#{index}",
      zone: zone2,
      last_seen_at: now - (10 + index).minutes,
      reported_zone_id: zone2.zone_id,
      health: index == 3 ? "degraded" : "ok",
      wifi_rssi: -63 - index,
      battery_voltage: 3.94 - (index * 0.05),
      last_error: index == 3 ? "stale sample" : "none",
      config_status: "applied",
      config_version: now.iso8601,
      moisture_raw_dry: 498,
      moisture_raw_wet: 640
    )
  end,
  zone3 => (1..2).map do |index|
    upsert_node(
      node_id: "demo-zone3-#{index}",
      zone: zone3,
      last_seen_at: now - (25 + index).minutes,
      reported_zone_id: zone3.zone_id,
      health: "ok",
      wifi_rssi: -59 - index,
      battery_voltage: 4.02 - (index * 0.04),
      last_error: "none",
      config_status: "applied",
      config_version: now.iso8601,
      moisture_raw_dry: 505,
      moisture_raw_wet: 655
    )
  end
}

unassigned_node_ids = 2.times.map do |index|
  node_id = "demo-unassigned-#{index + 1}"
  node = Node.find_or_initialize_by(node_id: "demo-unassigned-#{index + 1}")
  node.assign_attributes(
    zone: nil,
    reported_zone_id: "unassigned",
    last_seen_at: now - (5 + index).minutes,
    provisioned: true,
    health: "ok",
    wifi_rssi: -60 - index,
    battery_voltage: 4.0 - (index * 0.03),
    last_error: "none",
    config_status: "unassigned",
    config_version: now.iso8601,
    config_published_at: nil,
    config_acknowledged_at: nil,
    moisture_raw_dry: 520,
    moisture_raw_wet: 620
  )
  node.save!
  node_id
end

expected_demo_node_ids = zones_with_nodes.values.flatten.map(&:node_id) + unassigned_node_ids
stale_demo_node_ids = Node.where("node_id LIKE ?", "demo-%").where.not(node_id: expected_demo_node_ids).pluck(:node_id)
SensorReading.where(node_id: stale_demo_node_ids).delete_all if stale_demo_node_ids.any?
Node.where(node_id: stale_demo_node_ids).delete_all if stale_demo_node_ids.any?

zones_with_nodes.each do |zone, nodes|
  nodes.each_with_index do |node, index|
    rows = build_demo_readings(
      node: node,
      start_time: now - 9.days,
      count: 18,
      spacing_hours: zone == zone1 ? 12 : (zone == zone2 ? 18 : 24),
      base_percent: zone == zone1 ? (12 + index * 2) : (zone == zone2 ? 28 + index * 6 : 35 + index * 5),
      percent_step: zone == zone1 ? 4 : 3,
      raw_dry: node.moisture_raw_dry,
      raw_wet: node.moisture_raw_wet,
      battery_voltage: node.battery_voltage || 4.0,
      battery_percent: zone == zone1 ? 94 - index : 82 - index,
      ip_address: "192.168.4.#{30 + index + zone.irrigation_line}",
      health_pattern: lambda do |reading_index, _recorded_at|
        if zone == zone2 && index == 2 && reading_index >= 15
          "degraded"
        elsif zone == zone1 && index == 6 && reading_index >= 16
          "degraded"
        else
          "ok"
        end
      end,
      error_pattern: lambda do |reading_index, _recorded_at|
        if zone == zone2 && index == 2 && reading_index >= 15
          "stale sample"
        elsif zone == zone1 && index == 6 && reading_index == 17
          "sensor glitch"
        else
          "none"
        end
      end,
      reason_pattern: lambda do |reading_index, _recorded_at|
        case reading_index % 6
        when 0, 1, 4
          "interval"
        when 2
          "request_reading"
        when 3
          "manual_check"
        else
          "interval"
        end
      end,
      temp_base: zone == zone1 ? 22.1 : (zone == zone2 ? 23.2 : 24.4),
      rssi_base: node.wifi_rssi || -60
    )

    recreate_sensor_readings!(node: node, rows: rows)
  end
end

recreate_watering_history!(
  zone: zone1,
  completed_events: [
    { idempotency_key: "demo-zone1-water-001", issued_at: now - 8.days, runtime_seconds: 45, reason: "below_dry_threshold" },
    { idempotency_key: "demo-zone1-water-002", issued_at: now - 7.days + 3.hours, runtime_seconds: 45, reason: "manual_trigger" },
    { idempotency_key: "demo-zone1-water-003", issued_at: now - 6.days + 1.hour, runtime_seconds: 35, reason: "below_dry_threshold" },
    { idempotency_key: "demo-zone1-water-004", issued_at: now - 5.days + 5.hours, runtime_seconds: 45, reason: "manual_trigger" },
    { idempotency_key: "demo-zone1-water-005", issued_at: now - 4.days + 2.hours, runtime_seconds: 30, reason: "below_dry_threshold" },
    { idempotency_key: "demo-zone1-water-006", issued_at: now - 3.days + 4.hours, runtime_seconds: 45, reason: "manual_trigger" },
    { idempotency_key: "demo-zone1-water-007", issued_at: now - 2.days + 2.hours, runtime_seconds: 40, reason: "below_dry_threshold" },
    { idempotency_key: "demo-zone1-water-008", issued_at: now - 1.day + 6.hours, runtime_seconds: 45, reason: "manual_trigger" }
  ]
)

recreate_watering_history!(
  zone: zone2,
  completed_events: [
    { idempotency_key: "demo-zone2-water-001", issued_at: now - 8.days + 6.hours, runtime_seconds: 30, reason: "below_dry_threshold" },
    { idempotency_key: "demo-zone2-water-002", issued_at: now - 6.days + 8.hours, runtime_seconds: 30, reason: "manual_trigger" },
    { idempotency_key: "demo-zone2-water-003", issued_at: now - 4.days + 7.hours, runtime_seconds: 25, reason: "below_dry_threshold" },
    { idempotency_key: "demo-zone2-water-004", issued_at: now - 2.days + 9.hours, runtime_seconds: 30, reason: "below_dry_threshold" }
  ],
  fault_events: [
    {
      idempotency_key: "demo-zone2-water-fault-001",
      issued_at: now - 18.hours,
      runtime_seconds: 30,
      reason: "below_dry_threshold",
      actual_runtime_seconds: 8,
      fault_code: "DEMO_LOW_PRESSURE",
      fault_detail: "Demo actuator fault for history and health review"
    }
  ]
)

recreate_watering_history!(
  zone: zone3,
  completed_events: [
    { idempotency_key: "demo-zone3-water-001", issued_at: now - 7.days + 10.hours, runtime_seconds: 40, reason: "manual_trigger" },
    { idempotency_key: "demo-zone3-water-002", issued_at: now - 3.days + 11.hours, runtime_seconds: 35, reason: "below_dry_threshold" }
  ]
)

puts "Demo UI data ready:"
puts "- Zones: #{Zone.order(:zone_id).pluck(:zone_id).join(', ')}"
puts "- Demo assigned nodes: #{Node.where('node_id LIKE ?', 'demo-zone%').assigned.count}"
puts "- Demo unassigned nodes: #{Node.where('node_id LIKE ?', 'demo-unassigned-%').count}"
puts "- Demo readings: #{SensorReading.where('node_id LIKE ?', 'demo-%').count}"
puts "- Demo completed waterings: #{WateringEvent.where('idempotency_key LIKE ? AND status = ?', 'demo-%', 'completed').count}"
