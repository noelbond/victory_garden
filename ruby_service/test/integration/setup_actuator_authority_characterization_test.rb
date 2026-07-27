require "test_helper"

class SetupActuatorAuthorityCharacterizationTest < ActionDispatch::IntegrationTest
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

  test "characterizes bootstrap now exposing dedicated actuator provisioning authority" do
    ConnectionSetting.create!(
      mqtt_host: "broker.local",
      mqtt_port: 1883,
      mqtt_username: "victory_garden",
      mqtt_password: "secret123",
      irrigation_line_count: 4
    )
    create(:zone, irrigation_line: 1)

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body

    assert body.key?("setup_watering"), "watering authority is separate and already exposed"
    assert body.key?("setup_actuator")
    assert_equal true, body.dig("setup_actuator", "supported")
    assert_equal true, body.dig("setup_actuator", "authoritative")
    assert_equal "none", body.dig("setup_actuator", "state")
    assert_equal false, body.dig("setup_actuator", "complete")
    assert_nil body.dig("setup_actuator", "actuator")
    assert_not body.fetch("status").key?("actuator_ready")
    assert_equal true, body.dig("status", "watering_targets_ready")
  end

  test "currently watering target readiness can be true without observed actuator controller evidence" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    zone = create(:zone, irrigation_line: nil)
    node = create(
      :node,
      node_id: "sensor-zone1-ch0",
      zone: zone,
      crop_profile: zone.crop_profile,
      irrigation_line: 1
    )

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body

    assert_equal true, body.dig("status", "watering_targets_ready")
    assert_equal node.node_id, body.dig("assigned_node", "node_id")
    assert_equal 1, body.dig("assigned_node", "irrigation_line")
    assert_equal "none", body.dig("setup_actuator", "state")
    assert_equal false, body.dig("setup_actuator", "complete")
    assert_nil body.dig("status", "actuator_ready")
  end

  test "currently node status treats an actuator-like id as a generic node rather than controller authority" do
    zone = create(:zone)
    actuator_like_node = Node.create!(
      node_id: "actuator-zone1",
      zone: zone,
      reported_zone_id: zone.zone_id,
      last_seen_at: Time.current,
      provisioned: true,
      config_status: "applied"
    )

    get "/setup_api/node_status", params: { node_id: actuator_like_node.node_id }, as: :json

    assert_response :success
    body = response.parsed_body

    assert_equal true, body.fetch("detected")
    assert_equal actuator_like_node.node_id, body.dig("node", "node_id")
    assert_not body.fetch("node").key?("role")
    assert_not body.fetch("node").key?("device_uid")
    assert_not body.fetch("node").key?("outputs")
    assert_not body.fetch("node").key?("setup_actuator")
  end

  test "currently actuator status records target node without creating setup actuator authority" do
    crop = create(:crop_profile, crop_id: "tomato-loop")
    zone = create(:zone, zone_id: "zone1", crop_profile: crop)
    target_node = Node.create!(
      node_id: "sensor-zone1-ch0",
      zone: zone,
      crop_profile: crop,
      irrigation_line: 1,
      last_seen_at: Time.current
    )
    event = WateringEvent.create!(
      zone: zone,
      node_id: target_node.node_id,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "setup_validation",
      issued_at: Time.current,
      idempotency_key: "target-node-run-001",
      status: "running"
    )

    assert_no_difference -> { Node.count } do
      ActuatorStatusIngestor.new(
        "zone_id" => zone.zone_id,
        "node_id" => target_node.node_id,
        "state" => "COMPLETED",
        "timestamp" => Time.current.iso8601,
        "idempotency_key" => event.idempotency_key,
        "actual_runtime_seconds" => 44
      ).call
    end

    status = ActuatorStatus.order(:id).last
    assert_equal target_node.node_id, status.node_id
    assert_equal "completed", event.reload.status
    assert_nil Node.find_by(node_id: "actuator-zone1")

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    assert_equal "none", response.parsed_body.dig("setup_actuator", "state")
  end

  test "matching actuator config ack updates current actuator authority without a generic node row" do
    create(:actuator_device, logical_node_id: "actuator-zone1", state: "pending_observation", current: true, irrigation_line_count: 2)

    result = NodeConfigAckIngestor.new(
      "node_id" => "actuator-zone1",
      "status" => "applied",
      "timestamp" => Time.current.iso8601,
      "config_version" => "2026-07-27T12:00:00Z",
      "zone_id" => "zone1"
    ).call

    assert_equal "ready", result.state
    assert_nil Node.find_by(node_id: "actuator-zone1")
  end

  test "currently generic actuator-like nodes do not create actuator authority conflicts" do
    first_seen = Time.current
    Node.create!(node_id: "actuator-zone-a", last_seen_at: first_seen, provisioned: true)
    Node.create!(node_id: "actuator-zone-b", last_seen_at: first_seen + 1.minute, provisioned: true)

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body

    assert_equal "actuator-zone-b", body.dig("detected_node", "node_id")
    assert_equal "none", body.dig("setup_actuator", "state")
    assert_equal false, body.dig("setup_actuator", "complete")
    assert_not body.fetch("status").key?("actuator_conflict")
  end

  test "currently irrigation line evidence does not prove output inventory or physical ownership" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    zone = create(:zone, irrigation_line: nil)
    create(
      :node,
      node_id: "sensor-zone1-ch0",
      zone: zone,
      crop_profile: zone.crop_profile,
      irrigation_line: 3
    )

    get "/setup_api/bootstrap", as: :json

    assert_response :success
    body = response.parsed_body

    assert_equal true, body.dig("status", "watering_targets_ready")
    assert_equal 3, body.dig("assigned_node", "irrigation_line")
    assert_equal "none", body.dig("setup_actuator", "state")
    assert_equal false, body.dig("setup_actuator", "complete")
    assert_not body.dig("assigned_node").key?("output_inventory")
    assert_not body.dig("assigned_node").key?("actuator_node_id")
    assert_not body.dig("assigned_node").key?("firmware_version")
  end
end
