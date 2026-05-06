require "test_helper"

class OperatorPagesSmokeTest < ActionDispatch::IntegrationTest
  test "root onboarding and health pages render" do
    zone = create(:zone, name: "Greenhouse Zone 1")
    Node.create!(
      node_id: "pico-w-zone1",
      zone: zone,
      reported_zone_id: zone.zone_id,
      last_seen_at: 2.minutes.ago,
      provisioned: true,
      wifi_rssi: -48,
      health: "ok",
      last_error: "none",
      config_status: "applied",
      config_acknowledged_at: 1.minute.ago
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
    ConnectionSetting.create!(mqtt_host: "127.0.0.1", mqtt_port: 1883)

    get root_path
    assert_response :success
    assert_includes response.body, "Garden Dashboard"

    get onboarding_path
    assert_response :success
    assert_includes response.body, "Get Started"
    assert_includes response.body, "Progress"

    get health_path
    assert_response :success
    assert_includes response.body, "System Health"
    assert_includes response.body, "Nodes Online"
  end

  test "nodes page explains empty state when no nodes are discovered" do
    get nodes_path

    assert_response :success
    assert_includes response.body, "No Nodes Discovered Yet"
    assert_includes response.body, "Review Settings"
    assert_includes response.body, "Open Health"
  end

  test "health page explains config and runtime errors with fixes" do
    zone = create(:zone, name: "Greenhouse Zone 2")
    Node.create!(
      node_id: "demo-zone2-a",
      zone: zone,
      reported_zone_id: zone.zone_id,
      last_seen_at: 1.day.ago,
      provisioned: true,
      wifi_rssi: -72,
      health: "degraded",
      last_error: "stale sample",
      config_status: "error",
      config_published_at: 1.minute.ago,
      config_error: "Connection refused - connect(2) for \"localhost\" port 1883"
    )

    get health_path(health_tab: "nodes")

    assert_response :success
    assert_includes response.body, "Meaning:"
    assert_includes response.body, "Fix:"
    assert_includes response.body, "This app tried to publish config to a local MQTT broker on localhost:1883, but no broker accepted the connection."
    assert_includes response.body, "Open Settings and point MQTT host and port at the real broker for this environment, then use Republish Config again."
    assert_includes response.body, "The latest reading is too old to trust for current automation decisions."
    assert_includes response.body, "Check that the sensor node is still publishing on schedule and request a fresh reading if needed."
  end

  test "health page uses the expected interval for freshness and links open faults to recent faults" do
    zone = create(:zone, name: "Greenhouse Zone 3", publish_interval_ms: 3_600_000)
    Node.create!(
      node_id: "demo-zone3-a",
      zone: zone,
      reported_zone_id: zone.zone_id,
      last_seen_at: 30.minutes.ago,
      provisioned: true,
      wifi_rssi: -55,
      health: "ok",
      last_error: "none",
      config_status: "applied",
      config_acknowledged_at: 10.minutes.ago
    )
    SensorReading.create!(
      zone: zone,
      node_id: "demo-zone3-a",
      recorded_at: 30.minutes.ago,
      moisture_raw: 601,
      moisture_percent: 42.0,
      wifi_rssi: -55,
      health: "ok",
      last_error: "none",
      publish_reason: "interval",
      raw_payload: {}
    )
    Fault.create!(
      zone: zone,
      fault_code: "ACTUATOR_TIMEOUT",
      detail: "Actuator did not complete on time",
      recorded_at: 5.minutes.ago
    )

    get health_path

    assert_response :success
    assert_includes response.body, "seen in the expected interval"
    assert_includes response.body, "zones with a reading in the expected interval"
    refute_includes response.body, "within 5 minutes"
    assert_includes response.body, 'for="health-nav-faults"'
    refute_includes response.body, "Stale Readings"
    refute_includes response.body, "Stale Nodes"
  end
end
