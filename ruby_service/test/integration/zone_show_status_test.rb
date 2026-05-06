require "test_helper"

class ZoneShowStatusTest < ActionDispatch::IntegrationTest
  test "zone page highlights stale readings faults and actuator state" do
    zone = create(:zone, name: "Greenhouse Zone 1", active: true)
    Node.create!(
      node_id: "pico-w-zone1",
      zone: zone,
      reported_zone_id: zone.zone_id,
      last_seen_at: 2.hours.ago,
      provisioned: true,
      wifi_rssi: -55,
      health: "degraded",
      last_error: "sensor drift"
    )
    SensorReading.create!(
      zone: zone,
      node_id: "pico-w-zone1",
      recorded_at: 2.hours.ago,
      moisture_raw: 590,
      moisture_percent: 24.0,
      wifi_rssi: -55,
      health: "degraded",
      last_error: "sensor drift",
      publish_reason: "interval",
      raw_payload: {}
    )
    ActuatorStatus.create!(
      zone: zone,
      state: "RUNNING",
      recorded_at: 1.minute.ago,
      idempotency_key: "zone1-run",
      actual_runtime_seconds: 20
    )
    WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: 1.minute.ago,
      idempotency_key: "zone1-run",
      status: "running"
    )
    Fault.create!(
      zone: zone,
      fault_code: "STALE_SENSOR",
      detail: "Latest reading is too old for automatic decisions",
      recorded_at: 30.seconds.ago
    )

    get zone_path(zone)

    assert_response :success
    assert_includes response.body, "Notifications"
    assert_includes response.body, "Stale reading"
    assert_includes response.body, "Open faults"
    assert_includes response.body, "Watering active"
    assert_includes response.body, "Suggested fix:"
    assert_includes response.body, "The latest reading is too old to trust for current watering decisions."
    assert_includes response.body, "Check that the sensor node is online and publishing on schedule, then request or wait for a fresh reading."
    assert_includes response.body, "RUNNING"
    assert_includes response.body, "sensor drift"
    assert_includes response.body, "STALE_SENSOR"
    assert_includes response.body, "A sensor reading was considered too old to use safely for automatic decisions."
    assert_includes response.body, "Bring the sensor node back online and confirm a fresh reading is ingested before trusting automation."
    assert_includes response.body, "Zone History"
    assert_includes response.body, "Last 24h"
    assert_includes response.body, "Last 7d"
    assert_includes response.body, "Watering Events"
    assert_includes response.body, "Watering Runtime"
    assert_includes response.body, "Moisture Trend"
    assert_includes response.body, "Water Usage"
  end

  test "zone page shows aggregate moisture and sensor coverage details" do
    crop = create(:crop_profile, dry_threshold: 35.0)
    zone = create(:zone, name: "Aggregate Detail Zone", crop_profile: crop)

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

    get zone_path(zone)

    assert_response :success
    assert_includes response.body, "Zone Moisture Aggregate"
    assert_includes response.body, "Average Moisture: 30.0%"
    assert_includes response.body, "Average Raw: 520"
    assert_includes response.body, "Fresh Sensors: 2 / 4"
    assert_includes response.body, "Fresh Nodes: sensor-a, sensor-b"
    assert_includes response.body, "Stale Nodes: sensor-c"
    assert_includes response.body, "Missing Nodes: sensor-d"
    assert_includes response.body, "Partial aggregate"
  end

  test "zone nodes page shows only nodes claimed to that zone" do
    zone = create(:zone, name: "Zone With Nodes")
    other_zone = create(:zone, name: "Other Zone")

    Node.create!(
      node_id: "zone-node-a",
      zone: zone,
      reported_zone_id: zone.zone_id,
      last_seen_at: 2.minutes.ago,
      provisioned: true,
      health: "ok"
    )
    Node.create!(
      node_id: "zone-node-b",
      zone: zone,
      reported_zone_id: zone.zone_id,
      last_seen_at: 10.minutes.ago,
      provisioned: true,
      health: "degraded"
    )
    Node.create!(
      node_id: "other-zone-node",
      zone: other_zone,
      reported_zone_id: other_zone.zone_id,
      last_seen_at: 1.minute.ago,
      provisioned: true,
      health: "ok"
    )

    SensorReading.create!(
      zone: zone,
      node_id: "zone-node-a",
      recorded_at: 1.minute.ago,
      moisture_raw: 640,
      moisture_percent: 52.0,
      raw_payload: {}
    )

    get zone_nodes_path(zone)

    assert_response :success
    assert_includes response.body, "Zone With Nodes Nodes"
    assert_includes response.body, "2 claimed nodes for this zone."
    assert_includes response.body, "zone-node-a"
    assert_includes response.body, "zone-node-b"
    assert_includes response.body, "52.0%"
    assert_not_includes response.body, "other-zone-node"
  end
end
