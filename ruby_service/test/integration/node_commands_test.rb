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
    zone = create(:zone, zone_id: "zone1", publish_interval_ms: 3_600_000)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: 30.minutes.ago,
      moisture_raw: 500
    )

    assert_enqueued_with(job: RequestReadingJob) do
      post request_reading_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_includes flash[:notice], "Reading request queued"
    assert_includes flash[:notice], "next scheduled wake"
    assert_includes flash[:notice], "Restart the Pico"
    payload = enqueued_jobs.last[:args].first.with_indifferent_access
    assert_equal "zone1", payload[:zone_id]
    assert_equal "sensor-zone1", payload[:node_id]
    assert_match(/request-reading\z/, payload[:command_id])

    # Scheduled independently of RequestReadingJob (not from inside it), so
    # a publish failure still surfaces as a fault instead of leaving this
    # command stuck "queued" forever and silently blocking future requests.
    timeout_job = enqueued_jobs.find { |job| job[:job] == NodeCommandTimeoutJob }
    timeout_payload = timeout_job[:args].first.with_indifferent_access
    assert_equal payload[:command_id], timeout_payload[:command_id]
    assert_equal RequestReadingJob::TIMEOUT_SECONDS, timeout_payload[:timeout_seconds]
  end

  test "request reading debounces a second call for the same node within the window" do
    # test env runs on :null_store, which makes the debounce a no-op (every
    # read misses), so this needs a real cache to actually observe it.
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    begin
      zone = create(:zone, zone_id: "zone1")
      node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

      assert_enqueued_jobs 1, only: RequestReadingJob do
        post request_reading_node_path(node)
        post request_reading_node_path(node)
      end

      first_command_id = enqueued_jobs.last[:args].first.with_indifferent_access[:command_id]

      # The debounce cache window passing alone doesn't matter if the
      # earlier command is still unresolved (status stays "queued" here
      # since the job never actually runs against a real MQTT broker in
      # test) -- it keeps folding into the same command instead of piling
      # up a new one, even once the cache entry itself is gone.
      Rails.cache.delete("reading_request_debounce:#{node.node_id}")
      assert_no_enqueued_jobs only: RequestReadingJob do
        post request_reading_node_path(node)
      end
      assert_equal "queued", NodeCommand.find_by(command_id: first_command_id).status

      # Once the earlier command resolves, a fresh request is allowed again.
      NodeCommand.find_by(command_id: first_command_id).update!(status: "acknowledged")
      Rails.cache.delete("reading_request_debounce:#{node.node_id}")

      assert_enqueued_jobs 1, only: RequestReadingJob do
        post request_reading_node_path(node)
      end

      second_command_id = enqueued_jobs.select { |job| job[:job] == RequestReadingJob }.last[:args].first.with_indifferent_access[:command_id]
      refute_equal first_command_id, second_command_id
    ensure
      Rails.cache = original_cache
    end
  end

  test "request reading folds into an already-pending command even outside the debounce cache" do
    zone = create(:zone, zone_id: "zone1", publish_interval_ms: 3_600_000)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    NodeCommand.create!(
      zone: zone,
      node_id: node.node_id,
      command: "request_reading",
      command_id: "sensor-zone1-existing-request-reading",
      status: "command_sent",
      issued_at: 5.seconds.ago
    )

    assert_no_enqueued_jobs only: RequestReadingJob do
      post request_reading_node_path(node)
    end

    assert_equal 1, NodeCommand.where(node_id: node.node_id, command: "request_reading").count
  end

  test "request reading on an offline node redirects with alert and does not enqueue job" do
    zone = create(:zone, zone_id: "zone1", publish_interval_ms: 3_600_000)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: 3.hours.ago)

    assert_no_enqueued_jobs only: RequestReadingJob do
      post request_reading_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_includes flash[:alert], "offline"
  end

  test "request reading from health page redirects back to health" do
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    post request_reading_node_path(node), params: { return_to: health_path(health_tab: "nodes") }

    assert_redirected_to health_path(health_tab: "nodes")
  end

  test "manually water queues a targeted start command for a configured node" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop)
    node = Node.create!(node_id: "actuator-zone1", zone: zone, last_seen_at: Time.current, irrigation_line: 1)

    assert_enqueued_with(job: CommandPublishJob) do
      post manually_water_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_equal "Watering command queued for #{node.display_name}.", flash[:notice]
    event = WateringEvent.order(:id).last
    assert_equal zone, event.zone
    assert_equal node.node_id, event.node_id
    assert_equal "start_watering", event.command
    assert_equal "manual_trigger", event.reason
  end

  test "manually water on unassigned node redirects with alert and does not enqueue job" do
    node = Node.create!(node_id: "unassigned-node-water", last_seen_at: Time.current)

    assert_no_enqueued_jobs only: CommandPublishJob do
      post manually_water_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_equal "Assign the node before watering it.", flash[:alert]
  end

  test "manually water on node without a pump relay assigned redirects with alert" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop)
    node = Node.create!(node_id: "actuator-zone1", zone: zone, last_seen_at: Time.current)

    assert_no_enqueued_jobs only: CommandPublishJob do
      post manually_water_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_equal "Assign a crop profile and pump output before watering #{node.display_name}.", flash[:alert]
  end

  test "manually water on an offline node redirects with alert and does not enqueue job" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop, publish_interval_ms: 3_600_000)
    node = Node.create!(node_id: "actuator-zone1", zone: zone, last_seen_at: 3.hours.ago, irrigation_line: 1)

    assert_no_enqueued_jobs only: CommandPublishJob do
      post manually_water_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_includes flash[:alert], "offline"
  end

  test "manually water while a start command is already active for the node redirects with alert" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop)
    node = Node.create!(node_id: "actuator-zone1", zone: zone, last_seen_at: Time.current, irrigation_line: 1)
    WateringCommand.start_node(node)
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: CommandPublishJob do
      post manually_water_node_path(node)
    end

    assert_redirected_to node_path(node)
    assert_equal "Watering is already active for #{node.display_name}.", flash[:alert]
  end

  test "manually water from health page redirects back to health" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop)
    node = Node.create!(node_id: "actuator-zone1", zone: zone, last_seen_at: Time.current, irrigation_line: 1)

    post manually_water_node_path(node), params: { return_to: health_path(health_tab: "nodes") }

    assert_redirected_to health_path(health_tab: "nodes")
  end

  test "reboot enqueues a targeted reboot for an assigned node" do
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    assert_difference -> { NodeCommand.count }, 1 do
      assert_enqueued_with(job: RebootNodeJob) do
        post reboot_node_path(node)
      end
    end

    assert_redirected_to node_path(node)
    payload = enqueued_jobs.last[:args].first.with_indifferent_access
    assert_equal "zone1", payload[:zone_id]
    assert_equal "sensor-zone1", payload[:node_id]
    assert_match(/reboot\z/, payload[:command_id])

    command = NodeCommand.order(:id).last
    assert_equal zone, command.zone
    assert_equal "sensor-zone1", command.node_id
    assert_equal "reboot", command.command
    assert_equal "queued", command.status
    assert_equal payload[:command_id], command.command_id

    # Scheduled independently of RebootNodeJob (not from inside it), so a
    # publish failure still surfaces as a fault instead of leaving this
    # command stuck "queued" forever.
    timeout_job = enqueued_jobs.find { |job| job[:job] == NodeCommandTimeoutJob }
    timeout_payload = timeout_job[:args].first.with_indifferent_access
    assert_equal command.command_id, timeout_payload[:command_id]
    assert_equal RebootNodeJob::TIMEOUT_SECONDS, timeout_payload[:timeout_seconds]
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
    assert_includes response.body, "Manually Water"
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
    assert_includes response.body, "Recorded At,Moisture %,Moisture Raw,Air Temp F,Humidity %,Greenhouse Alert,Health,Last Error,Publish Reason,Wi-Fi RSSI,Wake Count,Uptime"
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
