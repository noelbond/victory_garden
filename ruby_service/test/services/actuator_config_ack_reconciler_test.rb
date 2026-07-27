require "test_helper"

class ActuatorConfigAckReconcilerTest < ActiveSupport::TestCase
  test "matching applied config acknowledgement marks current actuator ready" do
    actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: "pending_observation", current: true, irrigation_line_count: 2)

    result = ActuatorConfigAckReconciler.call(
      "node_id" => "actuator-zone1",
      "status" => "applied",
      "timestamp" => "2026-07-27T12:00:00Z",
      "zone_id" => "zone1"
    )

    assert_equal actuator.id, result.id
    assert_equal "ready", result.state
    assert_equal "applied", result.config_status
    assert_nil result.config_error
    assert_equal Time.iso8601("2026-07-27T12:00:00Z"), result.config_acknowledged_at
    assert_equal [1, 2], result.actuator_outputs.order(:output_index).pluck(:output_index)
    assert_equal true, SetupActuatorAuthority.bootstrap_payload.fetch(:complete)
  end

  test "matching failed config acknowledgement remains non-ready and redacts through bootstrap" do
    long_error = "x" * 400
    create(:actuator_device, logical_node_id: "actuator-zone1", state: "pending_observation", current: true, irrigation_line_count: 1)

    result = ActuatorConfigAckReconciler.call(
      "node_id" => "actuator-zone1",
      "status" => "failed",
      "error" => long_error
    )

    assert_equal "configured", result.state
    assert_equal "error", result.config_status
    assert_equal 300, result.config_error.length
    payload = SetupActuatorAuthority.bootstrap_payload
    assert_equal false, payload.fetch(:complete)
    assert_equal "present", payload.dig(:actuator, :config_error)
  end

  test "nonmatching acknowledgement does not create or update actuator authority" do
    actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: "pending_observation", current: true, irrigation_line_count: 2)

    result = ActuatorConfigAckReconciler.call(
      "node_id" => "actuator-zone2",
      "status" => "applied"
    )

    assert_nil result
    assert_equal "pending_observation", actuator.reload.state
    assert_equal 0, ActuatorOutput.count
  end

  test "historical actuator acknowledgement does not reactivate superseded records" do
    historical = create(:actuator_device, logical_node_id: "actuator-zone1", state: "inactive", current: false, superseded_at: Time.current, irrigation_line_count: 2)
    current = create(:actuator_device, logical_node_id: "actuator-zone2", state: "pending_observation", current: true, irrigation_line_count: 2)

    result = ActuatorConfigAckReconciler.call(
      "node_id" => "actuator-zone1",
      "status" => "applied"
    )

    assert_nil result
    assert_equal "inactive", historical.reload.state
    assert_equal "pending_observation", current.reload.state
  end

  test "unknown acknowledgement status is observed but not ready" do
    create(:actuator_device, logical_node_id: "actuator-zone1", state: "pending_observation", current: true, irrigation_line_count: 1)

    result = ActuatorConfigAckReconciler.call(
      "node_id" => "actuator-zone1",
      "status" => "received"
    )

    assert_equal "observed", result.state
    assert_equal "pending", result.config_status
    assert_equal false, SetupActuatorAuthority.bootstrap_payload.fetch(:complete)
  end
end
