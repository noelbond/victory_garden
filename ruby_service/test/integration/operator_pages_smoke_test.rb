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
end
