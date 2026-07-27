require "test_helper"

class SetupActuatorAuthorityTest < ActiveSupport::TestCase
  test "no current actuator returns none and incomplete" do
    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal true, payload.fetch(:supported)
    assert_equal true, payload.fetch(:authoritative)
    assert_equal "none", payload.fetch(:state)
    assert_equal false, payload.fetch(:complete)
    assert_nil payload.fetch(:actuator)
    assert_equal [], payload.fetch(:outputs)
  end

  test "pending observation is incomplete" do
    actuator = create_current_actuator(state: "pending_observation", irrigation_line_count: 2)
    create_outputs(actuator, 1..2)

    assert_incomplete_state "pending_observation"
  end

  test "observed is incomplete" do
    actuator = create_current_actuator(state: "observed", irrigation_line_count: 2)
    create_outputs(actuator, 1..2)

    assert_incomplete_state "observed"
  end

  test "configured is incomplete until readiness is satisfied" do
    actuator = create_current_actuator(state: "configured", irrigation_line_count: 2)
    create_outputs(actuator, 1..2)

    assert_incomplete_state "configured"
  end

  test "ready with valid complete output inventory is complete" do
    actuator = create_current_actuator(state: "ready", irrigation_line_count: 3, config_error: "wifi secret hidden")
    create_outputs(actuator, 1..3, state: "assigned")

    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal "ready", payload.fetch(:state)
    assert_equal "ready", payload.fetch(:persisted_state)
    assert_equal true, payload.fetch(:complete)
    assert_nil payload.fetch(:recovery)
    assert_equal actuator.logical_node_id, payload.dig(:actuator, :logical_node_id)
    assert_nil payload.dig(:actuator, :device_uid)
    assert_equal "present", payload.dig(:actuator, :config_error)
    assert_nil payload.dig(:actuator, :id)
    assert_equal [1, 2, 3], payload.fetch(:outputs).map { |output| output.fetch(:output_index) }
  end

  test "ready with missing output rows is safely incomplete" do
    actuator = create_current_actuator(state: "ready", irrigation_line_count: 3)
    create_outputs(actuator, [1, 2])

    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal "configured", payload.fetch(:state)
    assert_equal "ready", payload.fetch(:persisted_state)
    assert_equal false, payload.fetch(:complete)
    assert_equal "incomplete_output_inventory", payload.fetch(:recovery)
  end

  test "ready with output index gap is safely incomplete" do
    actuator = create_current_actuator(state: "ready", irrigation_line_count: 3)
    create_outputs(actuator, [1, 3])

    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal "configured", payload.fetch(:state)
    assert_equal false, payload.fetch(:complete)
    assert_equal "incomplete_output_inventory", payload.fetch(:recovery)
  end

  test "ready with faulted output is incomplete" do
    actuator = create_current_actuator(state: "ready", irrigation_line_count: 2)
    create_outputs(actuator, [1], state: "assigned")
    create(:actuator_output, actuator_device: actuator, output_index: 2, state: "faulted")

    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal false, payload.fetch(:complete)
    assert_equal "output_not_ready", payload.fetch(:recovery)
  end

  test "ready with unknown output is incomplete" do
    actuator = create_current_actuator(state: "ready", irrigation_line_count: 2)
    create_outputs(actuator, [1], state: "assigned")
    create(:actuator_output, actuator_device: actuator, output_index: 2, state: "unknown")

    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal false, payload.fetch(:complete)
    assert_equal "output_not_ready", payload.fetch(:recovery)
  end

  test "stale conflict and inactive states are incomplete" do
    %w[stale conflict inactive].each do |state|
      ActuatorOutput.delete_all
      ActuatorDevice.delete_all
      actuator = create_current_actuator(state: state, irrigation_line_count: 2)
      create_outputs(actuator, 1..2)

      payload = SetupActuatorAuthority.bootstrap_payload

      assert_equal state, payload.fetch(:state)
      assert_equal false, payload.fetch(:complete)
    end
  end

  test "superseded actuator is not selected as current" do
    actuator = create(:actuator_device, state: "inactive", current: false, superseded_at: Time.current)
    create_outputs(actuator, 1..2)

    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal "none", payload.fetch(:state)
    assert_equal false, payload.fetch(:complete)
  end

  test "historical actuator cannot satisfy bootstrap when another current actuator is incomplete" do
    historical = create(:actuator_device, state: "ready", current: false, irrigation_line_count: 2, superseded_at: Time.current)
    create_outputs(historical, 1..2)
    current = create_current_actuator(state: "observed", irrigation_line_count: 2)
    create_outputs(current, 1..2)

    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal current.logical_node_id, payload.dig(:actuator, :logical_node_id)
    assert_equal "observed", payload.fetch(:state)
    assert_equal false, payload.fetch(:complete)
  end

  test "ready with duplicate output indexes is prevented by the database" do
    actuator = create_current_actuator(state: "ready", irrigation_line_count: 2)
    create(:actuator_output, actuator_device: actuator, output_index: 1)

    assert_raises ActiveRecord::RecordNotUnique do
      ActuatorOutput.transaction(requires_new: true) do
        ActuatorOutput.new(actuator_device: actuator, output_index: 1, state: "assigned").save!(validate: false)
      end
    end
  end

  private

  def create_current_actuator(state:, irrigation_line_count:, **attrs)
    create(
      :actuator_device,
      {
        state: state,
        current: true,
        irrigation_line_count: irrigation_line_count,
        logical_node_id: "actuator-zone1"
      }.merge(attrs)
    )
  end

  def create_outputs(actuator, indexes, state: "assigned")
    indexes.each do |index|
      create(:actuator_output, actuator_device: actuator, output_index: index, state: state)
    end
  end

  def assert_incomplete_state(state)
    payload = SetupActuatorAuthority.bootstrap_payload

    assert_equal state, payload.fetch(:state)
    assert_equal false, payload.fetch(:complete)
    assert_equal "not_ready", payload.fetch(:recovery)
  end
end
