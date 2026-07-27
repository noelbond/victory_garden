require "test_helper"

class SetupApiTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "bootstrap returns current setup state" do
    setting = ConnectionSetting.create!(
      mqtt_host: "broker.local",
      mqtt_port: 1883,
      mqtt_username: "victory_garden",
      mqtt_password: "secret123",
      irrigation_line_count: 2
    )
    crop = CropProfile.create!(
      crop_name: "Tomatoes",
      dry_threshold: 32.0,
      max_pulse_runtime_sec: 45,
      daily_max_runtime_sec: 300
    )
    zone = Zone.create!(
      name: "Beds",
      crop_profile: crop,
      irrigation_line: 1,
      publish_interval_ms: 3_600_000
    )

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body.dig("status", "connection_ready")
    assert_equal true, body.dig("status", "first_zone_ready")
    assert_equal true, body.dig("status", "watering_targets_ready")
    assert_equal true, body.dig("status", "zone_ready")
    assert_equal setting.mqtt_host, body.dig("connection_setting", "mqtt_host")
    assert_equal setting.mqtt_username, body.dig("connection_setting", "provisioning_mqtt_username")
    assert_equal "secret123", body.dig("connection_setting", "provisioning_mqtt_password")
    assert_equal crop.crop_name, body.dig("crop_profiles", 0, "crop_name")
    assert_equal zone.name, body.dig("first_zone", "name")
    assert_nil body["assigned_node"]
    assert_equal "none", body.dig("setup_watering", "state")
    assert_equal false, body.dig("setup_watering", "complete")
    assert_equal true, body.dig("setup_actuator", "supported")
    assert_equal true, body.dig("setup_actuator", "authoritative")
    assert_equal "none", body.dig("setup_actuator", "state")
    assert_equal false, body.dig("setup_actuator", "complete")
    assert_nil body.dig("setup_actuator", "actuator")
  end

  test "connection update persists settings" do
    patch "/setup_api/connection",
          params: {
            connection_setting: {
              mqtt_host: "192.168.4.33",
              mqtt_port: 1883,
              mqtt_username: "victory_garden",
              mqtt_password: "secret123",
              irrigation_line_count: 4
            }
          },
          as: :json

    assert_response :success
    setting = ConnectionSetting.order(:id).last
    assert_equal "192.168.4.33", setting.mqtt_host
    assert_equal 4, setting.irrigation_line_count
    assert_equal "victory_garden", setting.mqtt_username
  end

  test "bootstrap exposes ready setup actuator without internal database ids" do
    actuator = ActuatorDevice.create!(
      logical_node_id: "actuator-zone1",
      firmware_kind: "actuator",
      state: "ready",
      current: true,
      irrigation_line_count: 2,
      device_uid: nil,
      zone_external_id: "zone1",
      board: "pico_w",
      config_status: "applied",
      config_acknowledged_at: Time.current
    )
    ActuatorOutput.create!(actuator_device: actuator, output_index: 1, state: "assigned")
    ActuatorOutput.create!(actuator_device: actuator, output_index: 2, state: "available")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    setup_actuator = response.parsed_body.fetch("setup_actuator")
    assert_equal true, setup_actuator.fetch("supported")
    assert_equal true, setup_actuator.fetch("authoritative")
    assert_equal "ready", setup_actuator.fetch("state")
    assert_equal true, setup_actuator.fetch("complete")
    assert_equal "actuator-zone1", setup_actuator.dig("actuator", "logical_node_id")
    assert_equal "actuator", setup_actuator.dig("actuator", "firmware_kind")
    assert_equal 2, setup_actuator.dig("actuator", "irrigation_line_count")
    assert_nil setup_actuator.dig("actuator", "id")
    assert_equal [1, 2], setup_actuator.fetch("outputs").map { |output| output.fetch("output_index") }
    assert_nil setup_actuator.fetch("outputs").first["id"]
  end

  test "bootstrap preserves watering and target readiness while adding setup actuator" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    zone = create(:zone, irrigation_line: nil)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 1)
    event = setup_validation_event(zone: zone, node: node, status: "completed", idempotency_key: "setup-watering-ready")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body.dig("status", "first_zone_ready")
    assert_equal true, body.dig("status", "watering_targets_ready")
    assert_equal true, body.dig("status", "zone_ready")
    assert_equal true, body.dig("status", "watering_ready")
    assert_equal event.idempotency_key, body.dig("setup_watering", "idempotency_key")
    assert_equal "completed", body.dig("setup_watering", "state")
    assert_equal "none", body.dig("setup_actuator", "state")
    assert_equal false, body.dig("setup_actuator", "complete")
  end

  test "crop profile creation returns validation errors" do
    post "/setup_api/crop_profile",
         params: {
           crop_profile: {
             crop_name: "",
             dry_threshold: 110,
             max_pulse_runtime_sec: 45,
             daily_max_runtime_sec: 30
           }
         },
         as: :json

    assert_response :unprocessable_entity
    errors = response.parsed_body.fetch("errors")
    assert errors.any? { |message| message.include?("Crop name") }
  end

  test "zone update creates first zone" do
    setting = ConnectionSetting.create!(
      mqtt_host: "broker.local",
      mqtt_port: 1883,
      mqtt_username: "victory_garden",
      mqtt_password: "secret123",
      irrigation_line_count: 2
    )
    crop = CropProfile.create!(
      crop_name: "Lettuce",
      dry_threshold: 28.0,
      max_pulse_runtime_sec: 30,
      daily_max_runtime_sec: 180
    )

    patch "/setup_api/zone",
          params: {
            zone: {
              name: "Front Planter",
              crop_profile_id: crop.id,
              irrigation_line: 2,
              publish_interval_ms: 7_200_000,
              active: true
            }
          },
          as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal "Front Planter", body.dig("first_zone", "name")
    assert_equal crop.id, body.dig("first_zone", "crop_profile_id")
    assert_equal true, body.dig("status", "first_zone_ready")
    assert_equal setting.irrigation_line_count, 2

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body.dig("status", "first_zone_ready")
    assert_equal true, body.dig("status", "watering_targets_ready")
    assert_equal true, body.dig("status", "zone_ready")
  end

  test "characterizes first zone readiness separately from watering target readiness" do
    crop = create(:crop_profile, crop_name: "Lettuce")

    patch "/setup_api/zone",
          params: {
            zone: {
              name: "Front Planter",
              crop_profile_id: crop.id,
              publish_interval_ms: 7_200_000,
              active: true
            }
          },
          as: :json

    assert_response :success
    body = response.parsed_body

    # STAB-004 characterization: a persisted zone with a crop profile is not
    # currently enough for setup `zone_ready`.
    assert_equal "Front Planter", body.dig("first_zone", "name")
    assert_nil body.dig("first_zone", "irrigation_line")
    assert_equal true, body.dig("status", "first_zone_ready")
    assert_equal false, body.dig("status", "watering_targets_ready")
    assert_equal false, body.dig("status", "zone_ready")
  end

  test "characterizes watering target readiness before calibration and readings" do
    zone = create(:zone, irrigation_line: nil)
    node = create(
      :node,
      node_id: "sensor-zone1-ch0",
      zone: zone,
      irrigation_line: 1
    )

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body

    # STAB-004 characterization: an assigned node irrigation line makes
    # `zone_ready` true even before calibration or a first reading.
    assert_equal node.node_id, body.dig("assigned_node", "node_id")
    assert_equal true, body.dig("status", "first_zone_ready")
    assert_equal true, body.dig("status", "watering_targets_ready")
    assert_equal true, body.dig("status", "zone_ready")
    assert_equal true, body.dig("status", "assigned_node_ready")
    assert_equal false, body.dig("status", "reading_ready")
    assert_equal false, body.dig("status", "calibration_ready")
  end

  test "node status reports whether a provisioned node has appeared" do
    zone = create(:zone, irrigation_line: nil)
    node = Node.create!(
      node_id: "sensor-zone1",
      last_seen_at: Time.current,
      zone: zone,
      reported_zone_id: zone.zone_id,
      provisioned: true
    )

    get "/setup_api/node_status", params: { node_id: node.node_id }, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body.fetch("detected")
    assert_equal true, body.fetch("assigned")
    assert_equal node.node_id, body.dig("node", "node_id")
    assert_equal zone.id, body.dig("node", "zone_id")
  end

  test "bootstrap groups the latest sensor channels by physical device" do
    channels = 4.times.map do |channel|
      Node.create!(
        node_id: "sensor-zone1-ch#{channel}",
        device_id: "sensor-zone1",
        last_seen_at: Time.current + channel.seconds,
        provisioned: true
      )
    end

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    detected = response.parsed_body.fetch("detected_node")
    assert_equal "sensor-zone1", detected.fetch("node_id")
    assert_equal "sensor-zone1", detected.fetch("device_id")
    assert_equal channels.map(&:node_id), detected.fetch("channels").map { |channel| channel.fetch("node_id") }
  end

  test "assign node binds detected node to first zone and queues global config publish" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1", last_seen_at: Time.current)

    assert_enqueued_with(job: ConfigPublishJob) do
      post "/setup_api/assign_node",
           params: { node_id: node.node_id, zone_id: zone.id },
           as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_equal true, body.fetch("assigned")
    assert_equal zone.id, node.reload.zone_id
    assert_equal zone.id, body.dig("node", "zone_id")
    assert_equal zone.zone_id, body.dig("first_zone", "zone_id")
  end

  test "assigning one channel assigns all physical device siblings" do
    zone = create(:zone)
    channels = 4.times.map do |channel|
      Node.create!(
        node_id: "sensor-zone1-ch#{channel}",
        device_id: "sensor-zone1",
        last_seen_at: Time.current
      )
    end

    post "/setup_api/assign_node",
         params: { node_id: channels.fetch(1).node_id, zone_id: zone.id },
         as: :json

    assert_response :success
    assert_equal [zone.id], Node.where(device_id: "sensor-zone1").distinct.pluck(:zone_id)
  end

  test "node update saves plant crop profile and pump output" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    zone = create(:zone, irrigation_line: nil)
    crop = create(:crop_profile, crop_name: "Squash")
    node = Node.create!(node_id: "sensor-zone1-ch0", device_id: "sensor-zone1", last_seen_at: Time.current, zone: zone)

    assert_enqueued_with(job: ConfigPublishJob) do
      patch "/setup_api/node",
            params: {
              node_id: node.node_id,
              name: "Bed One_Ch1",
              crop_profile_id: crop.id,
              irrigation_line: 1
            },
            as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "Bed One_Ch1", body.dig("node", "name")
    assert_equal crop.id, body.dig("node", "crop_profile_id")
    assert_equal 1, body.dig("node", "irrigation_line")
    assert_equal true, body.dig("node", "watering_configured")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal true, body.dig("status", "watering_targets_ready")
    assert_equal true, body.dig("status", "zone_ready")
  end

  test "request reading queues a targeted reading command and reports reading status" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    node = Node.create!(node_id: "sensor-zone1", last_seen_at: Time.current, zone: zone)
    SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: 30.minutes.ago,
      moisture_raw: 500
    )

    response_body = nil
    assert_enqueued_with(job: RequestReadingJob) do
      post "/setup_api/request_reading",
           params: { node_id: node.node_id },
           as: :json
      response_body = response.parsed_body
    end

    assert_response :success
    assert_equal true, response_body.fetch("queued")
    assert_equal node.node_id, response_body.dig("node", "node_id")
    assert_nil response_body.fetch("next_expected_wake_at")
    assert_includes response_body.fetch("message"), "Reading request queued"
    assert_includes response_body.fetch("message"), "Restart the Pico"

    get "/setup_api/reading_status",
        params: { node_id: node.node_id, since: response_body.fetch("requested_at") },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")

    reading = SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: Time.iso8601(response_body.fetch("requested_at")) + 2.seconds,
      moisture_raw: 412,
      moisture_percent: 41.2,
      publish_reason: "request_reading"
    )

    get "/setup_api/reading_status",
        params: { node_id: node.node_id, since: response_body.fetch("requested_at") },
        as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal true, body.fetch("complete")
    assert_equal reading.id, body.dig("reading", "id")
  end

  test "characterizes environmental-only reading as setup reading complete" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    node = create(:node, node_id: "sensor-zone1", zone: zone)
    requested_at = Time.current.utc
    reading = SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: requested_at + 2.seconds,
      air_temperature_c: 24.5,
      humidity_percent: 58,
      publish_reason: "periodic"
    )

    get "/setup_api/reading_status",
        params: { node_id: node.node_id, since: requested_at.iso8601 },
        as: :json

    assert_response :success
    body = response.parsed_body

    # STAB-004 characterization: the setup API treats any persisted reading
    # for the node as complete, even without moisture values.
    assert_equal true, body.fetch("complete")
    assert_equal reading.id, body.dig("reading", "id")
    assert_nil body.dig("reading", "moisture_raw")
    assert_nil body.dig("reading", "moisture_percent")
  end

  test "calibration update saves dry and wet raw values for the assigned node" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1", last_seen_at: Time.current, zone: zone)

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      patch "/setup_api/calibration",
            params: {
              node_id: node.node_id,
              moisture_raw_dry: 812,
              moisture_raw_wet: 326
            },
            as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_equal 812, body.dig("node", "moisture_raw_dry")
    assert_equal 326, body.dig("node", "moisture_raw_wet")
    assert_equal true, body.dig("node", "calibration_configured")
    assert_equal true, body.dig("status", "calibration_ready")
    assert_equal 812, node.reload.moisture_raw_dry
    assert_equal 326, node.moisture_raw_wet
  end

  test "start watering queues a manual watering cycle and reports watering status" do
    zone = create(:zone)

    response_body = nil
    assert_enqueued_with(job: CommandPublishJob) do
      post "/setup_api/start_watering",
           params: { zone_id: zone.id },
           as: :json
      response_body = response.parsed_body
    end

    assert_response :success
    assert_equal true, response_body.fetch("queued")
    event = WateringEvent.find_by!(idempotency_key: response_body.fetch("idempotency_key"))
    assert_equal "queued", event.status
    assert_equal true, event.setup_validation?
    assert_equal true, event.setup_current?
    assert_equal "zone", event.setup_target_kind
    assert_equal event.idempotency_key, response_body.dig("setup_watering", "idempotency_key")
    assert_equal "in_progress", response_body.dig("setup_watering", "state")

    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal false, response.parsed_body.fetch("terminal")
    assert_equal "in_progress", response.parsed_body.fetch("outcome")

    event.update!(status: "completed")
    status = ActuatorStatus.create!(
      zone: zone,
      state: "COMPLETED",
      idempotency_key: event.idempotency_key,
      recorded_at: event.issued_at + 10.seconds,
      actual_runtime_seconds: event.runtime_seconds
    )
    ActuatorStatus.create!(
      zone: zone,
      state: "COMPLETED",
      idempotency_key: "historical-other-key",
      recorded_at: event.issued_at + 20.seconds,
      actual_runtime_seconds: event.runtime_seconds
    )

    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal true, body.fetch("complete")
    assert_equal true, body.fetch("terminal")
    assert_equal "success", body.fetch("outcome")
    assert_equal event.id, body.dig("event", "id")
    assert_equal event.idempotency_key, body.dig("event", "idempotency_key")
    assert_equal status.id, body.dig("actuator_status", "id")
    assert_equal event.idempotency_key, body.dig("actuator_status", "idempotency_key")
    assert_equal true, body.dig("setup_watering", "complete")
    assert_equal "completed", body.dig("setup_watering", "state")
  end

  test "manual watering command does not create setup validation event" do
    zone = create(:zone)

    assert_enqueued_with(job: CommandPublishJob) do
      WateringCommand.start(zone)
    end

    event = WateringEvent.order(:id).last
    assert_equal "manual_trigger", event.reason
    assert_equal false, event.setup_validation?
    assert_equal false, event.setup_current?
  end

  test "automatic watering event does not create setup validation event" do
    zone = create(:zone)
    payload = {
      "action" => "water",
      "zone_id" => zone.zone_id,
      "runtime_seconds" => 10,
      "idempotency_key" => "automatic-controller-event",
      "timestamp" => Time.current.utc.iso8601
    }

    event = ControllerEventIngestor.new(payload).call

    assert_equal "below_dry_threshold", event.reason
    assert_equal false, event.setup_validation?
    assert_equal false, event.setup_current?
  end

  test "watering status reports explicit in-progress outcomes" do
    zone = create(:zone)
    active_statuses = %w[queued command_sent acknowledged running]

    active_statuses.each_with_index do |status, index|
      event = setup_watering_event(zone: zone, status: status, idempotency_key: "setup-active-#{status}", issued_at: (index + 1).minutes.ago)

      get "/setup_api/watering_status",
          params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
          as: :json

      assert_response :success
      assert_equal false, response.parsed_body.fetch("complete"), "#{status} should not complete setup"
      assert_equal false, response.parsed_body.fetch("terminal"), "#{status} should remain in progress"
      assert_equal "in_progress", response.parsed_body.fetch("outcome")
    end
  end

  test "watering status reports recovery outcomes without completing setup" do
    zone = create(:zone)
    recovery_statuses = {
      "stopped" => "stopped",
      "fault" => "faulted",
      "timeout" => "timed_out",
      "unknown" => "unknown"
    }

    recovery_statuses.each_with_index do |(status, outcome), index|
      event = setup_watering_event(zone: zone, status: status, idempotency_key: "setup-recovery-#{status}", issued_at: (index + 1).minutes.ago)

      get "/setup_api/watering_status",
          params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
          as: :json

      assert_response :success
      assert_equal false, response.parsed_body.fetch("complete"), "#{status} should not complete setup"
      assert_equal true, response.parsed_body.fetch("terminal"), "#{status} should be terminal recovery"
      assert_equal outcome, response.parsed_body.fetch("outcome")
    end
  end

  test "watering status requires supplied idempotency key and exact matching event" do
    zone = create(:zone)
    setup_watering_event(zone: zone, status: "completed", idempotency_key: "historical-completed", issued_at: 5.minutes.ago)

    get "/setup_api/watering_status",
        params: { zone_id: zone.id },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal true, response.parsed_body.fetch("terminal")
    assert_equal "missing_idempotency_key", response.parsed_body.fetch("outcome")
    assert_nil response.parsed_body.fetch("event")

    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: "missing-key" },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal true, response.parsed_body.fetch("terminal")
    assert_equal "not_found", response.parsed_body.fetch("outcome")
    assert_nil response.parsed_body.fetch("event")
  end

  test "historical completed event does not satisfy current running or faulted attempts" do
    zone = create(:zone)
    setup_watering_event(zone: zone, status: "completed", idempotency_key: "historical-completed", issued_at: 10.minutes.ago)

    running = setup_watering_event(zone: zone, status: "running", idempotency_key: "current-running", issued_at: 1.minute.ago)
    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: running.idempotency_key },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal false, response.parsed_body.fetch("terminal")
    assert_equal "in_progress", response.parsed_body.fetch("outcome")
    assert_equal running.id, response.parsed_body.dig("event", "id")

    fault = setup_watering_event(zone: zone, status: "fault", idempotency_key: "current-fault", issued_at: Time.current)
    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: fault.idempotency_key },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal true, response.parsed_body.fetch("terminal")
    assert_equal "faulted", response.parsed_body.fetch("outcome")
    assert_equal fault.id, response.parsed_body.dig("event", "id")
  end

  test "bootstrap watering readiness requires completed setup watering event" do
    zone = create(:zone)

    setup_validation_event(zone: zone, status: "completed", idempotency_key: "completed-ready")
    get "/setup_api/bootstrap", as: :json
    assert_response :success
    assert_equal true, response.parsed_body.dig("status", "watering_ready")
    assert_equal "completed", response.parsed_body.dig("setup_watering", "state")
    assert_equal true, response.parsed_body.dig("setup_watering", "complete")

    %w[stopped fault timeout unknown].each do |status|
      WateringEvent.delete_all
      setup_validation_event(zone: zone, status: status, idempotency_key: "bootstrap-#{status}")

      get "/setup_api/bootstrap", as: :json
      assert_response :success
      assert_equal false, response.parsed_body.dig("status", "watering_ready"), "#{status} should not satisfy watering readiness"
      assert_equal "recovery", response.parsed_body.dig("setup_watering", "state")
    end
  end

  test "bootstrap ignores completed ordinary and automatic watering events" do
    zone = create(:zone)
    WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 10,
      reason: "manual_trigger",
      issued_at: 5.minutes.ago,
      idempotency_key: "ordinary-completed",
      status: "completed"
    )
    ControllerEventIngestor.new(
      "action" => "water",
      "zone_id" => zone.zone_id,
      "runtime_seconds" => 10,
      "idempotency_key" => "automatic-completed",
      "timestamp" => 4.minutes.ago.utc.iso8601
    ).call.update!(status: "completed")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal false, response.parsed_body.dig("status", "watering_ready")
    assert_equal "none", response.parsed_body.dig("setup_watering", "state")
  end

  test "historical completed setup validation does not count after supersession" do
    zone = create(:zone)
    historical = setup_validation_event(zone: zone, status: "completed", idempotency_key: "historical-setup-completed")
    historical.supersede_setup_validation!(reason: "retry")
    setup_validation_event(zone: zone, status: "running", idempotency_key: "current-running-setup")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal false, response.parsed_body.dig("status", "watering_ready")
    assert_equal "in_progress", response.parsed_body.dig("setup_watering", "state")
    assert_equal "current-running-setup", response.parsed_body.dig("setup_watering", "idempotency_key")
  end

  test "completed setup validation for different zone does not count" do
    first_zone = create(:zone, zone_id: "zone-a")
    other_zone = create(:zone, zone_id: "zone-b")
    setup_validation_event(zone: other_zone, status: "completed", idempotency_key: "other-zone-completed")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal first_zone.id, response.parsed_body.dig("first_zone", "id")
    assert_equal false, response.parsed_body.dig("status", "watering_ready")
    assert_equal "target_changed", response.parsed_body.dig("setup_watering", "state")
    assert_equal "zone_changed", WateringEvent.find_by!(idempotency_key: "other-zone-completed").setup_invalidation_reason
  end

  test "completed setup validation for different node channel does not count" do
    zone = create(:zone, irrigation_line: nil)
    older_node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 1, last_seen_at: 2.minutes.ago)
    current_node = create(:node, node_id: "sensor-zone1-ch1", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 2, last_seen_at: Time.current)
    setup_validation_event(zone: zone, node: older_node, status: "completed", idempotency_key: "older-node-completed")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal current_node.node_id, response.parsed_body.dig("assigned_node", "node_id")
    assert_equal false, response.parsed_body.dig("status", "watering_ready")
    assert_equal "target_changed", response.parsed_body.dig("setup_watering", "state")
    assert_equal "node_changed", WateringEvent.find_by!(idempotency_key: "older-node-completed").setup_invalidation_reason
  end

  test "completed setup validation for changed output does not count" do
    zone = create(:zone, irrigation_line: 1)
    event = setup_validation_event(zone: zone, status: "completed", idempotency_key: "changed-output-completed")
    zone.update!(irrigation_line: 2)

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal false, response.parsed_body.dig("status", "watering_ready")
    assert_equal "target_changed", response.parsed_body.dig("setup_watering", "state")
    assert_equal "target_configuration_changed", event.reload.setup_invalidation_reason
  end

  test "unrelated target metadata change does not invalidate completed validation" do
    zone = create(:zone, irrigation_line: nil)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 1)
    event = setup_validation_event(zone: zone, node: node, status: "completed", idempotency_key: "node-name-change-completed")
    node.update!(name: "Kitchen Basil")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal true, response.parsed_body.dig("status", "watering_ready")
    assert_equal "completed", response.parsed_body.dig("setup_watering", "state")
    assert_nil event.reload.setup_invalidated_at
  end

  test "pending current setup validation blocks second start without publishing another command" do
    zone = create(:zone)
    setup_validation_event(zone: zone, status: "queued", idempotency_key: "pending-current")

    assert_no_enqueued_jobs only: CommandPublishJob do
      post "/setup_api/start_watering",
           params: { zone_id: zone.id },
           as: :json
    end

    assert_response :conflict
    assert_equal ["Watering validation is already active for setup."], response.parsed_body.fetch("errors")
    assert_equal 1, WateringEvent.setup_validations.count
    assert_equal "pending-current", response.parsed_body.dig("setup_watering", "idempotency_key")
  end

  test "running current setup validation blocks second start" do
    zone = create(:zone)
    setup_validation_event(zone: zone, status: "running", idempotency_key: "running-current")

    assert_no_enqueued_jobs only: CommandPublishJob do
      post "/setup_api/start_watering",
           params: { zone_id: zone.id },
           as: :json
    end

    assert_response :conflict
    assert_equal 1, WateringEvent.setup_validations.count
    assert_equal "running-current", WateringEvent.current_setup_validation.first.idempotency_key
  end

  test "terminal recovery setup validation can be deliberately superseded" do
    zone = create(:zone)
    old_event = setup_validation_event(zone: zone, status: "fault", idempotency_key: "faulted-current")

    assert_enqueued_with(job: CommandPublishJob) do
      post "/setup_api/start_watering",
           params: { zone_id: zone.id },
           as: :json
    end

    assert_response :success
    assert_equal false, old_event.reload.setup_current?
    assert_equal "retry", old_event.setup_supersession_reason
    assert_equal 2, WateringEvent.setup_validations.count
    assert_equal response.parsed_body.fetch("idempotency_key"), WateringEvent.current_setup_validation.first.idempotency_key
  end

  test "invalidated setup validation can be deliberately superseded" do
    zone = create(:zone, irrigation_line: 1)
    old_event = setup_validation_event(zone: zone, status: "completed", idempotency_key: "invalidated-current")
    zone.update!(irrigation_line: 2)

    get "/setup_api/bootstrap", as: :json
    assert_equal "target_changed", response.parsed_body.dig("setup_watering", "state")

    assert_enqueued_with(job: CommandPublishJob) do
      post "/setup_api/start_watering",
           params: { zone_id: zone.id },
           as: :json
    end

    assert_response :success
    assert_equal false, old_event.reload.setup_current?
    assert_equal "retry", old_event.setup_supersession_reason
  end

  test "missing referenced node fails setup readiness safely" do
    zone = create(:zone, irrigation_line: nil)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 1)
    event = setup_validation_event(zone: zone, node: node, status: "completed", idempotency_key: "missing-node-completed")
    node.destroy!

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal false, response.parsed_body.dig("status", "watering_ready")
    assert_equal "target_changed", response.parsed_body.dig("setup_watering", "state")
    assert_equal "node_missing", event.reload.setup_invalidation_reason
  end

  test "deleting assignment fails setup readiness safely" do
    zone = create(:zone, irrigation_line: nil)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 1)
    event = setup_validation_event(zone: zone, node: node, status: "completed", idempotency_key: "assignment-removed-completed")
    node.update!(zone: nil)

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal false, response.parsed_body.dig("status", "watering_ready")
    assert_equal "target_changed", response.parsed_body.dig("setup_watering", "state")
    assert_equal "node_missing", event.reload.setup_invalidation_reason
  end

  test "bootstrap and keyed watering status agree for current setup lifecycle" do
    zone = create(:zone)
    event = setup_validation_event(zone: zone, status: "completed", idempotency_key: "agree-completed")

    get "/setup_api/bootstrap", as: :json
    assert_response :success
    assert_equal true, response.parsed_body.dig("setup_watering", "complete")
    assert_equal "success", response.parsed_body.dig("setup_watering", "outcome")

    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    assert_equal true, response.parsed_body.fetch("complete")
    assert_equal "success", response.parsed_body.fetch("outcome")
    assert_equal "completed", response.parsed_body.dig("setup_watering", "state")
  end

  test "watering status without node parameter does not invalidate current node setup attempt" do
    zone = create(:zone, irrigation_line: nil)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 1)
    event = setup_validation_event(zone: zone, node: node, status: "running", idempotency_key: "node-status-no-param")

    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json

    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal "in_progress", response.parsed_body.fetch("outcome")
    assert_nil event.reload.setup_invalidated_at
  end

  test "rollback during setup validation start leaves no partial current state" do
    zone = create(:zone)

    stub_singleton_method(WateringCommand, :start_setup_validation, ->(target_zone, node: nil, enqueue: true) {
      runtime_seconds = target_zone.crop_profile.max_pulse_runtime_sec
      WateringEvent.create!(
        zone: target_zone,
        command: "start_watering",
        runtime_seconds: runtime_seconds,
        reason: "setup_validation",
        issued_at: Time.current,
        idempotency_key: "rollback-created",
        status: "queued",
        setup_validation: true,
        setup_current: true,
        **WateringEvent.setup_target_attributes(zone: target_zone, node: node, runtime_seconds: runtime_seconds)
      )
      raise ActiveRecord::Rollback
    }) do
      post "/setup_api/start_watering",
           params: { zone_id: zone.id },
           as: :json
    end

    assert_response :conflict
    assert_empty WateringEvent.where(idempotency_key: "rollback-created")
    assert_empty WateringEvent.current_setup_validation
  end

  test "watering status treats unrecognized response-boundary status as unsupported recovery" do
    zone = create(:zone)
    event = setup_watering_event(zone: zone, status: "queued", idempotency_key: "published-boundary")
    event.update_column(:status, "published")

    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal false, response.parsed_body.fetch("terminal")
    assert_equal "in_progress", response.parsed_body.fetch("outcome")

    event.update_column(:status, "faulted")
    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal true, response.parsed_body.fetch("terminal")
    assert_equal "faulted", response.parsed_body.fetch("outcome")

    event.update_column(:status, "timed_out")
    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal true, response.parsed_body.fetch("terminal")
    assert_equal "timed_out", response.parsed_body.fetch("outcome")

    event.update_column(:status, "rejected")
    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")
    assert_equal true, response.parsed_body.fetch("terminal")
    assert_equal "unsupported", response.parsed_body.fetch("outcome")
  end

  private

  def setup_watering_event(zone:, status:, idempotency_key:, issued_at: Time.current)
    WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 10,
      reason: "setup_characterization",
      issued_at: issued_at,
      idempotency_key: idempotency_key,
      status: status
    )
  end

  def setup_validation_event(zone:, status:, idempotency_key:, issued_at: Time.current, node: nil, current: true)
    runtime_seconds = (node&.effective_crop_profile || zone.crop_profile).max_pulse_runtime_sec
    attrs = {
      zone: zone,
      node_id: node&.node_id,
      command: "start_watering",
      runtime_seconds: runtime_seconds,
      reason: "setup_validation",
      issued_at: issued_at,
      idempotency_key: idempotency_key,
      status: status,
      setup_validation: true,
      setup_current: current
    }.merge(WateringEvent.setup_target_attributes(zone: zone, node: node, runtime_seconds: runtime_seconds))
    attrs[:setup_superseded_at] = 1.minute.ago unless current
    WateringEvent.create!(attrs)
  end
end
