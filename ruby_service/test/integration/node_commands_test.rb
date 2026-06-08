require "test_helper"

class NodeCommandsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "request reading enqueues a targeted request for an assigned node" do
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    assert_enqueued_with(job: RequestReadingJob) do
      post request_reading_node_path(node)
    end

    assert_redirected_to node_path(node)
    payload = enqueued_jobs.last[:args].first.with_indifferent_access
    assert_equal "zone1", payload[:zone_id]
    assert_equal "sensor-zone1", payload[:node_id]
    assert_match(/request-reading\z/, payload[:command_id])
  end

  test "request reading from health page redirects back to health" do
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    post request_reading_node_path(node), params: { return_to: health_path(health_tab: "nodes") }

    assert_redirected_to health_path(health_tab: "nodes")
  end

  test "reboot enqueues a targeted reboot for an assigned node" do
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    assert_enqueued_with(job: RebootNodeJob) do
      post reboot_node_path(node)
    end

    assert_redirected_to node_path(node)
    payload = enqueued_jobs.last[:args].first.with_indifferent_access
    assert_equal "zone1", payload[:zone_id]
    assert_equal "sensor-zone1", payload[:node_id]
    assert_match(/reboot\z/, payload[:command_id])
  end

  test "reboot from health page redirects back to health" do
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    post reboot_node_path(node), params: { return_to: health_path(health_tab: "nodes") }

    assert_redirected_to health_path(health_tab: "nodes")
  end

  test "republish config from health page redirects back to health" do
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    post publish_config_node_path(node), params: { return_to: health_path(health_tab: "nodes") }

    assert_redirected_to health_path(health_tab: "nodes")
  end

  test "node page shows request reading reboot and republish config actions" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    get node_path(node)

    assert_response :success
    assert_includes response.body, "Request Reading"
    assert_includes response.body, "Reboot Node"
    assert_includes response.body, "Republish Config"
    assert_includes response.body, "Sensor Calibration"
    assert_includes response.body, "Save Calibration"
    assert_includes response.body, "View Node Readings"
  end

  test "readings page shows individual readings and publish gaps" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: Time.utc(2026, 5, 9, 20, 17, 17),
      moisture_raw: 524,
      moisture_percent: 11.0,
      publish_reason: "interval",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )
    SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: Time.utc(2026, 5, 11, 10, 47, 40),
      moisture_raw: 542,
      moisture_percent: 29.0,
      publish_reason: "request_reading",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )

    get readings_node_path(node), params: { timeframe: "custom", from: "2026-05-09", to: "2026-05-11" }

    assert_response :success
    assert_includes response.body, "Node Readings"
    assert_includes response.body, "Publish Gaps"
    assert_includes response.body, "2026-05-11 10:47:40 UTC"
    assert_includes response.body, "missed about"
  end

  test "readings page exports csv" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: Time.utc(2026, 5, 11, 10, 47, 40),
      moisture_raw: 542,
      moisture_percent: 29.0,
      publish_reason: "request_reading",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )

    get readings_node_path(node, format: :csv), params: { timeframe: "custom", from: "2026-05-11", to: "2026-05-11" }

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Recorded At,Moisture %,Moisture Raw,Soil Temp C,Battery %,Health,Last Error,Publish Reason,Wi-Fi RSSI,Wake Count,Uptime"
    assert_includes response.body, "2026-05-11T10:47:40Z,29.0,542"
    assert_includes response.body, "request_reading"
  end

  test "updating node calibration saves and redirects to node show" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    patch update_calibration_node_path(node), params: {
      node: { moisture_raw_dry: 552, moisture_raw_wet: 943 }
    }

    assert_redirected_to node_path(node)
    assert_equal "Node calibration updated.", flash[:notice]
    assert_equal 552, node.reload.moisture_raw_dry
    assert_equal 943, node.moisture_raw_wet
  end

  test "request reading on unassigned node redirects with alert and does not enqueue job" do
    node = Node.create!(node_id: "unassigned-node", last_seen_at: Time.current)

    assert_no_enqueued_jobs only: RequestReadingJob do
      post request_reading_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_equal "Assign the node before requesting a reading.", flash[:alert]
  end

  test "reboot on unassigned node redirects with alert and does not enqueue job" do
    node = Node.create!(node_id: "unassigned-node-reboot", last_seen_at: Time.current)

    assert_no_enqueued_jobs only: RebootNodeJob do
      post reboot_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_equal "Assign the node before sending a reboot command.", flash[:alert]
  end

  test "crop profile on unassigned node redirects with alert and does not update zone" do
    crop = create(:crop_profile)
    node = Node.create!(node_id: "unassigned-node-crop", last_seen_at: Time.current)

    patch crop_profile_node_path(node), params: { crop_profile_id: crop.id }

    assert_redirected_to node_path(node)
    assert_equal "Assign the node before applying a crop profile.", flash[:alert]
  end

  test "node page explains runtime and config errors with fixes" do
    zone = create(:zone)
    node = Node.create!(
      node_id: "sensor-zone1",
      zone: zone,
      last_seen_at: Time.current,
      last_error: "stale sample",
      config_status: "error",
      config_error: "Connection refused - connect(2) for \"localhost\" port 1883"
    )

    get node_path(node)

    assert_response :success
    assert_includes response.body, "Meaning:"
    assert_includes response.body, "Fix:"
    assert_includes response.body, "The latest reading is too old to trust for current automation decisions."
    assert_includes response.body, "This app tried to publish config to a local MQTT broker on localhost:1883, but no broker accepted the connection."
  end
end
