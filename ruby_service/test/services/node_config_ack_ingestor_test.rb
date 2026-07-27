require "test_helper"

class NodeConfigAckIngestorTest < ActiveSupport::TestCase
  setup do
    @zone = create(:zone, zone_id: "zone1")
    @node = Node.create!(
      node_id: "pico-zone1",
      zone: @zone,
      last_seen_at: Time.current,
      desired_config: {
        "assigned" => true,
        "zone_id" => "zone1",
        "crop_id" => @zone.crop_profile.crop_id
      },
      config_status: "pending"
    )
  end

  test "applied ack falls back to desired config when applied_config is omitted" do
    payload = {
      "node_id" => @node.node_id,
      "status" => "applied",
      "timestamp" => "2026-04-06T20:00:00Z",
      "config_version" => "2026-04-06T19:59:00Z",
      "zone_id" => "zone1"
    }

    node = NodeConfigAckIngestor.new(payload).call

    assert_equal "applied", node.config_status
    assert_equal @node.desired_config, node.applied_config
    assert_equal "2026-04-06T19:59:00Z", node.config_version
    assert_equal "zone1", node.reported_zone_id
    assert_equal Time.iso8601("2026-04-06T20:00:00Z"), node.config_acknowledged_at
  end

  test "failed ack maps to error status and keeps explicit applied_config" do
    payload = {
      "node_id" => @node.node_id,
      "status" => "failed",
      "timestamp" => "2026-04-06T20:00:00Z",
      "applied_config" => { "assigned" => false },
      "error" => "flash write failed"
    }

    node = NodeConfigAckIngestor.new(payload).call

    assert_equal "error", node.config_status
    assert_equal({ "assigned" => false }, node.applied_config)
    assert_equal "flash write failed", node.config_error
  end

  test "unknown ack status maps to pending" do
    payload = {
      "node_id" => @node.node_id,
      "status" => "received"
    }

    node = NodeConfigAckIngestor.new(payload).call

    assert_equal "pending", node.config_status
    assert node.config_acknowledged_at.present?
  end

  test "matching actuator ack reconciles current actuator instead of requiring a generic node row" do
    actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: "pending_observation", current: true, irrigation_line_count: 2)

    result = NodeConfigAckIngestor.new(
      "node_id" => "actuator-zone1",
      "status" => "applied",
      "timestamp" => "2026-07-27T12:00:00Z"
    ).call

    assert_equal actuator.id, result.id
    assert_equal "ready", result.state
    assert_nil Node.find_by(node_id: "actuator-zone1")
  end

  test "unmatched actuator-like ack keeps the existing generic node not found behavior" do
    assert_raises(ActiveRecord::RecordNotFound) do
      NodeConfigAckIngestor.new(
        "node_id" => "actuator-zone-missing",
        "status" => "applied"
      ).call
    end
  end
end
