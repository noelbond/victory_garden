require "test_helper"

class OperatorPagesSmokeTest < ActionDispatch::IntegrationTest
  setup do
    @mqtt_consumer_status_path = MqttConsumer::STATUS_PATH
    @mqtt_consumer_status_backup = @mqtt_consumer_status_path.exist? ? File.read(@mqtt_consumer_status_path) : nil
    @firstboot_state_dir = Dir.mktmpdir("vg-firstboot")
    @firstboot_state_dir_before = ENV["VG_FIRSTBOOT_STATE_DIR"]
    ENV["VG_FIRSTBOOT_STATE_DIR"] = @firstboot_state_dir
    @firmware_bundle_dir = Dir.mktmpdir("vg-firmware-bundles")
    @firmware_bundle_dir_before = ENV["VG_FIRMWARE_BUNDLE_ROOT"]
    ENV["VG_FIRMWARE_BUNDLE_ROOT"] = @firmware_bundle_dir
    %w[
      pico_w_sensor_node.uf2
      pico2_w_sensor_node.uf2
      pico_w_actuator_node.uf2
      pico2_w_actuator_node.uf2
    ].each do |filename|
      File.write(File.join(@firmware_bundle_dir, filename), "bundle:#{filename}\n")
    end
  end

  teardown do
    if @mqtt_consumer_status_backup.nil?
      File.delete(@mqtt_consumer_status_path) if @mqtt_consumer_status_path.exist?
    else
      FileUtils.mkdir_p(@mqtt_consumer_status_path.dirname)
      File.write(@mqtt_consumer_status_path, @mqtt_consumer_status_backup)
    end

    ENV["VG_FIRSTBOOT_STATE_DIR"] = @firstboot_state_dir_before
    FileUtils.rm_rf(@firstboot_state_dir) if @firstboot_state_dir.present?
    ENV["VG_FIRMWARE_BUNDLE_ROOT"] = @firmware_bundle_dir_before
    FileUtils.rm_rf(@firmware_bundle_dir) if @firmware_bundle_dir.present?
  end

  test "root onboarding and health pages render" do
    zone = create(:zone, name: "Greenhouse Zone 1", irrigation_line: 1)
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
    WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: 1.minute.ago,
      idempotency_key: "zone1-bootstrap-1",
      status: "completed"
    )
    ConnectionSetting.create!(mqtt_host: "127.0.0.1", mqtt_port: 1883, mqtt_username: "victory_garden", mqtt_password: "secret123", irrigation_line_count: 1)

    get root_path
    assert_response :success
    assert_includes response.body, "Garden Dashboard"

    get onboarding_path
    assert_response :success
    assert_includes response.body, "Setup Wizard"
    assert_includes response.body, "Wizard Steps"
    assert_includes response.body, "Required Progress"

    get health_path
    assert_response :success
    assert_includes response.body, "System Health"
    assert_includes response.body, "Fresh Nodes"
  end

  test "root redirects to onboarding while setup is incomplete" do
    get root_path

    assert_redirected_to onboarding_path
  end

  test "onboarding defaults to the first incomplete required step" do
    get onboarding_path

    assert_response :success
    assert_includes response.body, "Current Step"
    assert_includes response.body, "MQTT host, port, username, and password still need setup."
  end

  test "onboarding firmware flow exposes Pico 2 W bundles and instructions" do
    get onboarding_path(step: "firmware", sensor_board: "pico2_w", actuator_board: "pico2_w")

    assert_response :success
    assert_includes response.body, "Pico 2 W"
    assert_includes response.body, "RP2350"
    assert_includes response.body, "Download Sensor Firmware"
    assert_includes response.body, "Download Actuator Firmware"

    get onboarding_path(step: "detected_node", sensor_board: "pico2_w", actuator_board: "pico2_w")

    assert_response :success
    assert_includes response.body, "pico2_w_sensor_node.uf2"
    assert_includes response.body, "RP2350"

    get onboarding_firmware_path(kind: "actuator", board: "pico2_w")

    assert_response :success
    assert_includes response.headers["Content-Disposition"], "pico2_w_actuator_node.uf2"
  end

  test "health page shows degraded mqtt consumer state" do
    FileUtils.mkdir_p(@mqtt_consumer_status_path.dirname)
    File.write(
      @mqtt_consumer_status_path,
      JSON.pretty_generate(
        {
          component: "mqtt_consumer",
          status: "degraded",
          connected: false,
          retry_count: 3,
          last_error: "MQTT::ProtocolException boom",
          next_retry_at: "2026-05-26T15:00:10Z",
          updated_at: "2026-05-26T15:00:06Z"
        }
      )
    )

    get health_path

    assert_response :success
    assert_includes response.body, "MQTT Consumer"
    assert_includes response.body, "Degraded"
    assert_includes response.body, "Last error: MQTT::ProtocolException boom."
  end

  test "onboarding and health surface firstboot failure state and log download" do
    File.write(File.join(@firstboot_state_dir, "firstboot-failed"), "")
    File.write(
      File.join(@firstboot_state_dir, "firstboot.log"),
      <<~LOG
        preparing repo
        running install_pi.sh
        bundle install failed
      LOG
    )

    get onboarding_path

    assert_response :success
    assert_includes response.body, "Image Provisioning Status"
    assert_includes response.body, "Failed"
    assert_includes response.body, "bundle install failed"
    assert_includes response.body, "Download First-Boot Log"

    get onboarding_firstboot_log_path

    assert_response :success
    assert_equal "preparing repo\nrunning install_pi.sh\nbundle install failed\n", response.body

    get health_path

    assert_response :success
    assert_includes response.body, "Image Provisioning"
    assert_includes response.body, "first boot needs review"
    assert_includes response.body, "Image provisioning failed before the install reached a healthy running state."
  end

  test "nodes page explains empty state when no nodes are discovered" do
    get nodes_path

    assert_response :success
    assert_includes response.body, "No Nodes Discovered Yet"
    assert_includes response.body, "Open Settings"
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
    assert_includes response.body, "Node Readings"
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
