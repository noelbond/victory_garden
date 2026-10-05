require "test_helper"

class ZonesDashboardTest < ActionDispatch::IntegrationTest
  test "root dashboard shows zone overview metrics and cards" do
    ConnectionSetting.create!(mqtt_host: "broker.local", mqtt_port: 1883, mqtt_username: "victory_garden", mqtt_password: "secret123", irrigation_line_count: 2)
    zone = create(:zone, name: "Greenhouse Zone 1", active: true)
    SensorZoneProvisioner.call(zone: zone, sensor_device_id: "sensor-#{zone.zone_id}")
    node = zone.nodes.find_by!(node_id: "sensor-#{zone.zone_id}-ch0")
    node.update!(
      name: "Cherry Tomato A",
      reported_zone_id: zone.zone_id,
      last_seen_at: 2.minutes.ago,
      provisioned: true,
      wifi_rssi: -48,
      health: "ok",
      last_error: "none"
    )
    SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: 2.minutes.ago,
      moisture_raw: 615,
      moisture_percent: 85.0,
      wifi_rssi: -48,
      health: "ok",
      last_error: "none",
      publish_reason: "interval",
      raw_payload: {}
    )
    ActuatorStatus.create!(
      zone: zone,
      state: "RUNNING",
      recorded_at: 1.minute.ago,
      idempotency_key: "zone1-1",
      actual_runtime_seconds: 12
    )
    WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: 1.minute.ago,
      idempotency_key: "zone1-1",
      status: "completed"
    )
    Fault.create!(
      zone: zone,
      fault_code: "NO_FLOW",
      detail: "Pump reported no flow",
      recorded_at: 30.seconds.ago
    )

    get root_path

    assert_response :success
    assert_includes response.body, "Garden Dashboard"
    assert_includes response.body, "Fresh Nodes"
    assert_includes response.body, "Watering Now"
    assert_includes response.body, "Open Fault Zones"
    assert_includes response.body, "Greenhouse Zone 1"
    assert_includes response.body, "Cherry Tomato A"
    assert_includes response.body, "85.0%"
    assert_includes response.body, "RUNNING"
    refute_includes response.body, "`RUNNING`"
    assert_includes response.body, "1 fault"
    refute_includes response.body, stop_watering_zone_path(zone)
  end

  test "root dashboard shows zone aggregate moisture and sensor coverage" do
    ConnectionSetting.create!(mqtt_host: "broker.local", mqtt_port: 1883, mqtt_username: "victory_garden", mqtt_password: "secret123", irrigation_line_count: 2)
    zone = create(:zone, name: "Aggregated Zone")

    SensorZoneProvisioner.call(zone: zone, sensor_device_id: "sensor-#{zone.zone_id}")
    nodes = zone.nodes.order(:node_id).to_a
    nodes.each do |node|
      node.update!(
        reported_zone_id: zone.zone_id,
        last_seen_at: 2.minutes.ago,
        provisioned: true
      )
    end

    SensorReading.create!(
      zone: zone,
      node_id: nodes[0].node_id,
      recorded_at: 2.minutes.ago,
      moisture_raw: 500,
      moisture_percent: 20.0,
      raw_payload: {}
    )
    SensorReading.create!(
      zone: zone,
      node_id: nodes[1].node_id,
      recorded_at: 1.minute.ago,
      moisture_raw: 540,
      moisture_percent: 40.0,
      raw_payload: {}
    )
    SensorReading.create!(
      zone: zone,
      node_id: nodes[2].node_id,
      recorded_at: 20.minutes.ago,
      moisture_raw: 900,
      moisture_percent: 90.0,
      raw_payload: {}
    )
    WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 30,
      reason: "manual_trigger",
      issued_at: 10.minutes.ago,
      idempotency_key: "aggregated-zone-1",
      status: "completed"
    )

    get root_path

    assert_response :success
    assert_includes response.body, "Fresh Nodes"
    assert_includes response.body, "Aggregated Zone"
    assert_includes response.body, "Zone Average"
    assert_includes response.body, "30.0%"
    assert_includes response.body, "raw avg 520"
    assert_includes response.body, "2 / 4 fresh"
  end
end
