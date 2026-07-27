require "test_helper"

class SetupWateringTargetAuthorityTest < ActiveSupport::TestCase
  test "ready current actuator output satisfies active zone target" do
    create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
    actuator = create_ready_actuator(line_count: 2)

    result = SetupWateringTargetAuthority.call

    assert_predicate result, :ready?
    assert_nil result.reason
    assert_equal actuator, result.actuator
    assert_equal 1, result.required_target_count
    assert_equal 1, result.mapped_target_count
    assert_equal [1], result.referenced_output_indexes
  end

  test "no current actuator cannot satisfy watering targets" do
    create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "no_current_actuator", result.reason
  end

  test "non-ready current actuator states cannot satisfy watering targets" do
    %w[pending_observation observed configured stale conflict inactive].each do |state|
      ActuatorOutput.delete_all
      ActuatorDevice.delete_all
      Zone.delete_all

      create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
      actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: state, current: true, irrigation_line_count: 2)
      create_outputs(actuator, [1, 2], state: "assigned")

      result = SetupWateringTargetAuthority.call

      assert_equal false, result.ready?, "#{state} should not satisfy target readiness"
      assert_equal "actuator_not_ready", result.reason
    end
  end

  test "historical ready actuator cannot satisfy current actuator target readiness" do
    historical = create(:actuator_device, logical_node_id: "actuator-old", state: "ready", current: false, superseded_at: Time.current, irrigation_line_count: 2)
    create_outputs(historical, [1, 2], state: "assigned")
    create(:actuator_device, logical_node_id: "actuator-new", state: "observed", current: true, irrigation_line_count: 2)
    create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "actuator_not_ready", result.reason
  end

  test "missing output inventory cannot satisfy watering targets" do
    create(:zone, zone_id: "zone1", irrigation_line: 2, active: true)
    actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: "ready", current: true, irrigation_line_count: 2)
    create(:actuator_output, actuator_device: actuator, output_index: 1, state: "assigned")

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "actuator_not_ready", result.reason
  end

  test "faulted target output cannot satisfy watering targets" do
    create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
    actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: "ready", current: true, irrigation_line_count: 2)
    create(:actuator_output, actuator_device: actuator, output_index: 1, state: "faulted")
    create(:actuator_output, actuator_device: actuator, output_index: 2, state: "available")

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "actuator_not_ready", result.reason
  end

  test "disabled and unknown target outputs cannot satisfy watering targets" do
    %w[disabled unknown].each do |state|
      ActuatorOutput.delete_all
      ActuatorDevice.delete_all
      Zone.delete_all

      create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
      actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: "ready", current: true, irrigation_line_count: 2)
      create(:actuator_output, actuator_device: actuator, output_index: 1, state: state)
      create(:actuator_output, actuator_device: actuator, output_index: 2, state: "available")

      result = SetupWateringTargetAuthority.call

      assert_equal false, result.ready?, "#{state} should not satisfy target readiness"
      assert_equal "actuator_not_ready", result.reason
    end
  end

  test "active node target uses node irrigation line before zone fallback" do
    zone = create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 2)
    create_ready_actuator(line_count: 2)

    result = SetupWateringTargetAuthority.call

    assert_predicate result, :ready?
    assert_equal [["zone", "zone1", 1], ["node", node.node_id, 2]], target_tuples(result)
  end

  test "active node target may use zone irrigation line fallback" do
    zone = create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: nil)
    create_ready_actuator(line_count: 2)

    result = SetupWateringTargetAuthority.call

    assert_predicate result, :ready?
    assert_includes target_tuples(result), ["node", node.node_id, 1]
  end

  test "assigned node without node or zone line is a missing output recovery state" do
    zone = create(:zone, zone_id: "zone1", irrigation_line: nil, active: true)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: nil)
    create_ready_actuator(line_count: 2)

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "missing_output", result.reason
    assert_equal [node.node_id], result.missing_targets.map(&:identifier)
  end

  test "out of range watering line is a missing output recovery state" do
    create(:zone, zone_id: "zone1", irrigation_line: 3, active: true)
    create_ready_actuator(line_count: 2)

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "invalid_mapping", result.reason
  end

  test "zero and negative watering lines are invalid mappings" do
    zone = create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
    create_ready_actuator(line_count: 2)

    [0, -1].each do |line|
      zone.update_column(:irrigation_line, line)

      result = SetupWateringTargetAuthority.call

      assert_equal false, result.ready?, "line #{line} should not satisfy target readiness"
      assert_equal "invalid_mapping", result.reason
      assert_equal [line], result.invalid_targets.map(&:irrigation_line)
    end
  end

  test "one invalid target makes the whole result incomplete" do
    create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
    invalid_zone = create(:zone, zone_id: "zone2", irrigation_line: 2, active: true)
    invalid_zone.update_column(:irrigation_line, 0)
    create_ready_actuator(line_count: 2)

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "invalid_mapping", result.reason
    assert_equal ["zone2"], result.invalid_targets.map(&:identifier)
  end

  test "extra unused ready output does not fail target readiness" do
    create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
    create_ready_actuator(line_count: 3)

    result = SetupWateringTargetAuthority.call

    assert_predicate result, :ready?
  end

  test "inactive watering targets are excluded" do
    create(:zone, zone_id: "zone1", irrigation_line: 1, active: false)
    create_ready_actuator(line_count: 2)

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "no_watering_targets", result.reason
  end

  test "multiple targets may share one ready output" do
    zone = create(:zone, zone_id: "zone1", irrigation_line: 1, active: true)
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: nil)
    create_ready_actuator(line_count: 1)

    result = SetupWateringTargetAuthority.call

    assert_predicate result, :ready?
    assert_equal [["zone", zone.zone_id, 1], ["node", node.node_id, 1]], target_tuples(result)
  end

  test "current replacement actuator is evaluated instead of historical outputs" do
    create(:zone, zone_id: "zone1", irrigation_line: 2, active: true)
    historical = create(:actuator_device, logical_node_id: "actuator-old", state: "ready", current: false, superseded_at: Time.current, irrigation_line_count: 2)
    create_outputs(historical, [1, 2], state: "assigned")
    current = create(:actuator_device, logical_node_id: "actuator-new", state: "ready", current: true, irrigation_line_count: 1)
    create(:actuator_output, actuator_device: current, output_index: 1, state: "assigned")

    result = SetupWateringTargetAuthority.call

    assert_equal false, result.ready?
    assert_equal "invalid_mapping", result.reason
    assert_equal current, result.actuator

    current.update!(irrigation_line_count: 2)
    create(:actuator_output, actuator_device: current, output_index: 2, state: "available")
    result = SetupWateringTargetAuthority.call

    assert_predicate result, :ready?
    assert_equal current, result.actuator
  end

  private

  def create_ready_actuator(line_count:, output_states: {})
    actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: "ready", current: true, irrigation_line_count: line_count)
    create_outputs(actuator, 1..line_count, state: "assigned", output_states: output_states)
    actuator
  end

  def create_outputs(actuator, indexes, state:, output_states: {})
    indexes.each do |index|
      create(:actuator_output, actuator_device: actuator, output_index: index, state: output_states.fetch(index, state))
    end
  end

  def target_tuples(result)
    result.targets.map { |target| [target.kind, target.identifier, target.irrigation_line] }
  end
end
