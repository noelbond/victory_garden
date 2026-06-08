require "test_helper"

class SetupApiTest < ActionDispatch::IntegrationTest
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
    assert_equal setting.mqtt_host, body.dig("connection_setting", "mqtt_host")
    assert_equal setting.mqtt_username, body.dig("connection_setting", "provisioning_mqtt_username")
    assert_equal "secret123", body.dig("connection_setting", "provisioning_mqtt_password")
    assert_equal crop.crop_name, body.dig("crop_profiles", 0, "crop_name")
    assert_equal zone.name, body.dig("first_zone", "name")
    assert_nil body["assigned_node"]
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
    assert_equal setting.irrigation_line_count, 2
  end

  test "node status reports whether a provisioned node has appeared" do
    zone = create(:zone)
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

  test "assign node binds detected node to first zone and queues node config publish" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1", last_seen_at: Time.current)

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
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

  test "request reading queues a targeted reading command and reports reading status" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1", last_seen_at: Time.current, zone: zone)

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

    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    assert_equal false, response.parsed_body.fetch("complete")

    event.update!(status: "completed")
    status = ActuatorStatus.create!(
      zone: zone,
      state: "COMPLETED",
      recorded_at: event.issued_at + 10.seconds,
      actual_runtime_seconds: event.runtime_seconds
    )

    get "/setup_api/watering_status",
        params: { zone_id: zone.id, idempotency_key: event.idempotency_key },
        as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal true, body.fetch("complete")
    assert_equal event.id, body.dig("event", "id")
    assert_equal status.id, body.dig("actuator_status", "id")
  end
end
