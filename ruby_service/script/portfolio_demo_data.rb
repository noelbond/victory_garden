class PortfolioDemoData
  ZONE_DEFINITIONS = [
    {
      zone_id: "north-canopy",
      name: "North Canopy",
      package_id: "vg-north",
      crop_ids: %w[cherry-tomato cherry-tomato bell-pepper bell-pepper],
      node_names: [ "Cherry Tomato A", "Cherry Tomato B", "Bell Pepper A", "Bell Pepper B" ],
      moisture_base: 55.0,
      temperature_base: 23.0,
      humidity_base: 61.0,
      rssi_base: -51
    },
    {
      zone_id: "herb-bench",
      name: "Herb Bench",
      package_id: "vg-herbs",
      crop_ids: %w[basil basil leaf-lettuce leaf-lettuce],
      node_names: [ "Genovese Basil A", "Genovese Basil B", "Leaf Lettuce A", "Leaf Lettuce B" ],
      moisture_base: 62.0,
      temperature_base: 21.5,
      humidity_base: 66.0,
      rssi_base: -57
    }
  ].freeze

  CROP_DEFINITIONS = [
    {
      crop_id: "cherry-tomato",
      crop_name: "Cherry Tomato",
      dry_threshold: 34.0,
      max_pulse_runtime_sec: 40,
      daily_max_runtime_sec: 260,
      climate_preference: "Warm with steady moisture",
      time_to_harvest_days: 70
    },
    {
      crop_id: "bell-pepper",
      crop_name: "Bell Pepper",
      dry_threshold: 36.0,
      max_pulse_runtime_sec: 35,
      daily_max_runtime_sec: 240,
      climate_preference: "Warm and bright",
      time_to_harvest_days: 75
    },
    {
      crop_id: "basil",
      crop_name: "Genovese Basil",
      dry_threshold: 42.0,
      max_pulse_runtime_sec: 25,
      daily_max_runtime_sec: 180,
      climate_preference: "Warm with even moisture",
      time_to_harvest_days: 50
    },
    {
      crop_id: "leaf-lettuce",
      crop_name: "Leaf Lettuce",
      dry_threshold: 46.0,
      max_pulse_runtime_sec: 20,
      daily_max_runtime_sec: 160,
      climate_preference: "Cool with even moisture",
      time_to_harvest_days: 35
    }
  ].freeze

  READINGS_PER_NODE = 121
  READING_INTERVAL = 6.hours
  IRRIGATION_LINE_COUNT = 8
  CONNECTION_NOTE = "Synthetic local portfolio dataset; does not establish service connectivity"

  def self.seed!(now: Time.current.change(sec: 0))
    new(now:).seed!
  end

  def initialize(now:)
    @now = now
  end

  def seed!
    ensure_isolated_database!

    ActiveRecord::Base.transaction do
      setting = upsert_connection_setting!
      crops = upsert_crops!
      zones = upsert_zones!
      clear_portfolio_history!(zones)
      nodes = configure_nodes!(zones, crops)
      create_readings!(nodes)
      create_watering_history!(nodes)
      Fault.where(zone: zones.values).delete_all

      verify_dataset!(setting:, zones:, nodes:)
    end

    print_summary
  end

  private

  attr_reader :now

  def portfolio_zone_ids
    ZONE_DEFINITIONS.map { |definition| definition.fetch(:zone_id) }
  end

  def portfolio_crop_ids
    CROP_DEFINITIONS.map { |definition| definition.fetch(:crop_id) }
  end

  def portfolio_node_ids
    ZONE_DEFINITIONS.flat_map do |definition|
      Node.canonical_package_node_ids(definition.fetch(:package_id))
    end
  end

  def ensure_isolated_database!
    unexpected_zones = Zone.where.not(zone_id: portfolio_zone_ids).limit(3).pluck(:zone_id)
    unexpected_nodes = Node.where.not(node_id: portfolio_node_ids).limit(3).pluck(:node_id)
    unexpected_crops = CropProfile.where.not(crop_id: portfolio_crop_ids).limit(3).pluck(:crop_id)
    unexpected_settings = ConnectionSetting.where(notes: nil).exists? || ConnectionSetting.where.not(notes: CONNECTION_NOTE).exists?

    return if unexpected_zones.empty? && unexpected_nodes.empty? && unexpected_crops.empty? && !unexpected_settings && ConnectionSetting.count <= 1

    examples = (unexpected_zones + unexpected_nodes + unexpected_crops).first(3).join(", ")
    raise <<~MESSAGE.squish
      Portfolio demo generation refused because this database contains non-portfolio application data#{": #{examples}" if examples.present?}.
      Create an empty dedicated database and load the schema before running this scenario.
    MESSAGE
  end

  def upsert_connection_setting!
    setting = ConnectionSetting.first_or_initialize
    setting.assign_attributes(
      mqtt_host: "localhost",
      mqtt_port: 1883,
      mqtt_username: "portfolio_local",
      mqtt_password: "synthetic-local-only",
      irrigation_line_count: IRRIGATION_LINE_COUNT,
      readings_topic: "greenhouse/zones/+/nodes/+/state",
      actuators_topic: "greenhouse/zones/+/actuator/status",
      command_topic: "greenhouse/zones/{zone_id}/actuator/command",
      config_topic: "greenhouse/system/config/current",
      bluetooth_enabled: false,
      notes: CONNECTION_NOTE
    )
    setting.save!
    setting
  end

  def upsert_crops!
    CROP_DEFINITIONS.index_by { |definition| definition.fetch(:crop_id) }.transform_values do |definition|
      CropProfile.find_or_initialize_by(crop_id: definition.fetch(:crop_id)).tap do |crop|
        crop.assign_attributes(definition.merge(active: true))
        crop.save!
      end
    end
  end

  def upsert_zones!
    ZONE_DEFINITIONS.to_h do |definition|
      zone = Zone.find_or_initialize_by(zone_id: definition.fetch(:zone_id))
      zone.assign_attributes(
        name: definition.fetch(:name),
        active: true,
        publish_interval_ms: 3_600_000,
        allowed_hours: { "start_hour" => 6, "end_hour" => 20 }
      )
      zone.save!
      SensorZoneProvisioner.call(zone:, sensor_device_id: definition.fetch(:package_id))
      [ definition.fetch(:zone_id), zone.reload ]
    end
  end

  def clear_portfolio_history!(zones)
    zone_records = zones.values
    NodeCommand.where(zone: zone_records).delete_all
    ActuatorStatus.where(zone: zone_records).delete_all
    WateringEvent.where(zone: zone_records).delete_all
    SensorReading.where(zone: zone_records).delete_all
    Fault.where(zone: zone_records).delete_all
  end

  def configure_nodes!(zones, crops)
    line = 0

    ZONE_DEFINITIONS.flat_map do |definition|
      zone = zones.fetch(definition.fetch(:zone_id))
      node_ids = Node.canonical_package_node_ids(definition.fetch(:package_id))

      node_ids.each_with_index.map do |node_id, index|
        line += 1
        node = zone.nodes.find_by!(node_id:)
        crop = crops.fetch(definition.fetch(:crop_ids).fetch(index))
        calibration_dry = 520 + (index * 7)
        calibration_wet = 850 + (index * 6)
        config_version = (now - 5.minutes).utc.iso8601
        config = {
          "node_id" => node_id,
          "zone_id" => zone.zone_id,
          "crop_id" => crop.crop_id,
          "irrigation_line" => line,
          "moisture_raw_dry" => calibration_dry,
          "moisture_raw_wet" => calibration_wet
        }

        node.update!(
          name: definition.fetch(:node_names).fetch(index),
          crop_profile: crop,
          irrigation_line: line,
          active: true,
          provisioned: true,
          schema_version: "node-state/v1",
          reported_zone_id: zone.zone_id,
          last_seen_at: now - 1.minute,
          health: "ok",
          wifi_rssi: definition.fetch(:rssi_base) - index,
          battery_voltage: 4.08 - (index * 0.02),
          last_error: "none",
          config_status: "applied",
          config_version:,
          config_published_at: now - 5.minutes,
          config_acknowledged_at: now - 4.minutes,
          config_error: nil,
          moisture_raw_dry: calibration_dry,
          moisture_raw_wet: calibration_wet,
          desired_config: config,
          applied_config: config
        )
        node
      end
    end
  end

  def create_readings!(nodes)
    nodes.each_with_index do |node, node_index|
      definition = ZONE_DEFINITIONS.find { |candidate| candidate.fetch(:zone_id) == node.zone.zone_id }
      end_time = now - 1.minute
      start_time = end_time - 30.days

      READINGS_PER_NODE.times do |reading_index|
        recorded_at = start_time + (reading_index * READING_INTERVAL)
        phase = (reading_index % 20) / 20.0
        day_phase = (reading_index % 4) / 4.0
        moisture_percent = definition.fetch(:moisture_base) - (phase * 17.0) + ((node_index % 4) * 1.4)
        air_temperature_c = definition.fetch(:temperature_base) + Math.sin(day_phase * 2 * Math::PI) * 2.8
        humidity_percent = definition.fetch(:humidity_base) - Math.sin(day_phase * 2 * Math::PI) * 6.0
        battery_voltage = 4.15 - ((reading_index.to_f / (READINGS_PER_NODE - 1)) * 0.18) - ((node_index % 4) * 0.01)
        wifi_rssi = definition.fetch(:rssi_base) - (node_index % 4) - (reading_index % 3)
        moisture_raw = node.moisture_raw_dry + (((node.moisture_raw_wet - node.moisture_raw_dry) * moisture_percent) / 100.0).round

        SensorReading.create!(
          zone: node.zone,
          node_id: node.node_id,
          recorded_at:,
          schema_version: "node-state/v1",
          moisture_raw:,
          moisture_percent: moisture_percent.round(1),
          soil_moisture_read: true,
          soil_temp_c: (air_temperature_c - 1.2).round(1),
          air_temperature_c: air_temperature_c.round(1),
          humidity_percent: humidity_percent.round(1),
          greenhouse_alert_status: "normal",
          battery_voltage: battery_voltage.round(2),
          battery_percent: (((battery_voltage - 3.4) / 0.8) * 100).clamp(0, 100).round,
          wifi_rssi:,
          uptime_seconds: 1_800 + (reading_index * READING_INTERVAL.to_i),
          wake_count: 500 + reading_index,
          ip_address: nil,
          health: "ok",
          last_error: "none",
          publish_reason: reading_index == READINGS_PER_NODE - 1 ? "scheduled" : "interval",
          raw_payload: {
            "schema_version" => "node-state/v1",
            "node_id" => node.node_id,
            "zone_id" => node.zone.zone_id,
            "synthetic" => true
          }
        )
      end

      latest = SensorReading.where(node_id: node.node_id).order(recorded_at: :desc).first!
      node.update!(
        last_seen_at: latest.recorded_at,
        battery_voltage: latest.battery_voltage,
        wifi_rssi: latest.wifi_rssi,
        health: latest.health,
        last_error: latest.last_error
      )
    end
  end

  def create_watering_history!(nodes)
    nodes.each_with_index do |node, node_index|
      [ 24, 17, 10, 3 ].each_with_index do |days_ago, event_index|
        issued_at = now - days_ago.days + (8 + (node_index % 4)).hours
        next unless issued_at < now

        runtime_seconds = [ node.crop_profile.max_pulse_runtime_sec - (event_index * 3), 12 ].max
        key = "portfolio-#{node.node_id}-#{event_index + 1}"

        WateringEvent.create!(
          zone: node.zone,
          node_id: node.node_id,
          command: "start_watering",
          runtime_seconds:,
          reason: event_index.even? ? "below_dry_threshold" : "manual_trigger",
          issued_at:,
          idempotency_key: key,
          status: "completed"
        )

        ActuatorStatus.create!(
          zone: node.zone,
          node_id: node.node_id,
          state: "ACKNOWLEDGED",
          recorded_at: issued_at + 1.second,
          idempotency_key: key,
          actual_runtime_seconds: 0
        )
        ActuatorStatus.create!(
          zone: node.zone,
          node_id: node.node_id,
          state: "RUNNING",
          recorded_at: issued_at + 2.seconds,
          idempotency_key: key,
          actual_runtime_seconds: 0
        )
        ActuatorStatus.create!(
          zone: node.zone,
          node_id: node.node_id,
          state: "COMPLETED",
          recorded_at: issued_at + runtime_seconds.seconds,
          idempotency_key: key,
          actual_runtime_seconds: runtime_seconds,
          flow_ml: runtime_seconds * 12
        )
      end
    end
  end

  def verify_dataset!(setting:, zones:, nodes:)
    raise "portfolio setting is incomplete" unless setting.mqtt_host.present? && setting.mqtt_port.present? && setting.mqtt_username.present? && setting.mqtt_password.present? && setting.irrigation_line_count == IRRIGATION_LINE_COUNT
    raise "portfolio zones are not canonical" unless zones.values.all?(&:canonical_sensor_package_nodes?)
    raise "portfolio node count is invalid" unless nodes.size == ZONE_DEFINITIONS.size * Node::EXPECTED_CHANNELS_PER_DEVICE
    raise "portfolio irrigation routing is invalid" unless nodes.all?(&:irrigation_line_supported?)
    raise "portfolio config acknowledgements are incomplete" unless nodes.all? { |node| node.config_status == "applied" && node.config_acknowledged_at.present? }
    raise "portfolio telemetry is incomplete" unless nodes.all? { |node| SensorReading.where(node_id: node.node_id).count == READINGS_PER_NODE }
    raise "portfolio telemetry contains future timestamps" if SensorReading.where(zone: zones.values).where("recorded_at >= ?", now).exists?
    raise "portfolio telemetry is not fresh" unless nodes.all? { |node| node.last_seen_at.between?(now - 2.minutes, now) }
    raise "portfolio watering history is incomplete" unless WateringEvent.where(zone: zones.values, status: "completed").where.not(node_id: nil).exists?
    raise "portfolio faults must be resolved or absent" if Fault.where(zone: zones.values, resolved_at: nil).exists?
  end

  def print_summary
    puts "Portfolio demo UI data ready:"
    puts "- Synthetic zones: #{portfolio_zone_ids.join(', ')}"
    puts "- Canonical nodes: #{Node.where(node_id: portfolio_node_ids).count}"
    puts "- Historical readings: #{SensorReading.where(node_id: portfolio_node_ids).count}"
    puts "- Completed waterings: #{WateringEvent.where(node_id: portfolio_node_ids, status: 'completed').count}"
    puts "- Service health files: unchanged"
  end
end
