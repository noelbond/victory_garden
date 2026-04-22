require "test_helper"

class ZonesDashboardTest < ActionDispatch::IntegrationTest
  test "root dashboard shows zone overview metrics and cards" do
    zone = create(:zone, name: "Greenhouse Zone 1", active: true)
    Node.create!(
      node_id: "pico-w-zone1",
      zone: zone,
      reported_zone_id: zone.zone_id,
      last_seen_at: 2.minutes.ago,
      provisioned: true,
      wifi_rssi: -48,
      health: "ok",
      last_error: "none"
    )
    SensorReading.create!(
      zone: zone,
      node_id: "pico-w-zone1",
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
      status: "running"
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
    assert_includes response.body, "Fresh Sensors"
    assert_includes response.body, "Watering Now"
    assert_includes response.body, "Open Fault Zones"
    assert_includes response.body, "Greenhouse Zone 1"
    assert_includes response.body, "85.0%"
    assert_includes response.body, "RUNNING"
    assert_includes response.body, "1 fault"
  end

  test "root dashboard shows zone aggregate moisture and sensor coverage" do
    crop = create(:crop_profile, dry_threshold: 35.0)
    zone = create(:zone, name: "Aggregated Zone", crop_profile: crop)

    %w[sensor-a sensor-b sensor-c sensor-d].each do |node_id|
      Node.create!(
        node_id: node_id,
        zone: zone,
        reported_zone_id: zone.zone_id,
        last_seen_at: 2.minutes.ago,
        provisioned: true
      )
    end

    SensorReading.create!(
      zone: zone,
      node_id: "sensor-a",
      recorded_at: 2.minutes.ago,
      moisture_raw: 500,
      moisture_percent: 20.0,
      raw_payload: {}
    )
    SensorReading.create!(
      zone: zone,
      node_id: "sensor-b",
      recorded_at: 1.minute.ago,
      moisture_raw: 540,
      moisture_percent: 40.0,
      raw_payload: {}
    )
    SensorReading.create!(
      zone: zone,
      node_id: "sensor-c",
      recorded_at: 20.minutes.ago,
      moisture_raw: 900,
      moisture_percent: 90.0,
      raw_payload: {}
    )

    get root_path

    assert_response :success
    assert_includes response.body, "Fresh Sensors"
    assert_includes response.body, "Aggregated Zone"
    assert_includes response.body, "Zone Average"
    assert_includes response.body, "30.0%"
    assert_includes response.body, "raw avg 520"
    assert_includes response.body, "2 / 4 fresh"
  end
end
