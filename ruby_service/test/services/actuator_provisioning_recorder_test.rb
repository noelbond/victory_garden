require "test_helper"

class ActuatorProvisioningRecorderTest < ActiveSupport::TestCase
  setup do
    ConnectionSetting.create!(irrigation_line_count: 3)
  end

  test "records a pending current actuator provisioning attempt with expected outputs" do
    result = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w"
    )

    assert result.success?
    actuator = result.actuator
    assert_equal "pending_observation", actuator.state
    assert_equal "pending", actuator.config_status
    assert_equal true, actuator.current
    assert_equal "actuator-zone1", actuator.logical_node_id
    assert_equal "provision-001", actuator.provisioning_operation_id
    assert_equal "zone1", actuator.zone_external_id
    assert_equal "pico_w", actuator.board
    assert_equal 3, actuator.irrigation_line_count
    assert_equal [1, 2, 3], actuator.actuator_outputs.order(:output_index).pluck(:output_index)
    assert_equal %w[available available available], actuator.actuator_outputs.order(:output_index).pluck(:state)
  end

  test "same provisioning operation is idempotent for the same current actuator" do
    first = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w"
    )

    second = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w"
    )

    assert second.success?
    assert_equal first.actuator.id, second.actuator.id
    assert_equal 1, ActuatorDevice.current.count
    assert_equal 3, second.actuator.actuator_outputs.count
  end

  test "same logical actuator reprovision refreshes current record without duplicating outputs" do
    first = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w"
    )
    first.actuator.update!(
      state: "ready",
      config_acknowledged_at: Time.current,
      config_status: "applied",
      config_error: "stale"
    )

    second = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-002",
      zone_external_id: "zone1",
      board: "pico2_w"
    )

    assert second.success?
    assert_equal first.actuator.id, second.actuator.id
    assert_equal "pending_observation", second.actuator.state
    assert_equal "pending", second.actuator.config_status
    assert_nil second.actuator.config_acknowledged_at
    assert_nil second.actuator.config_error
    assert_equal "provision-002", second.actuator.provisioning_operation_id
    assert_equal "pico2_w", second.actuator.board
    assert_equal [1, 2, 3], second.actuator.actuator_outputs.order(:output_index).pluck(:output_index)
  end

  test "reused provisioning operation id with conflicting identity fails" do
    ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w"
    )

    result = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone2",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone2",
      board: "pico_w"
    )

    assert_not result.success?
    assert_equal :conflict, result.status
    assert_equal "actuator-zone1", ActuatorDevice.current_device.logical_node_id
  end

  test "new logical actuator supersedes prior current actuator without deleting history" do
    old_result = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w"
    )

    new_result = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone2",
      provisioning_operation_id: "provision-002",
      zone_external_id: "zone2",
      board: "pico2_w"
    )

    assert new_result.success?
    assert_equal "actuator-zone2", ActuatorDevice.current_device.logical_node_id
    assert_equal false, old_result.actuator.reload.current
    assert_equal "inactive", old_result.actuator.state
    assert_equal ActuatorDevice::CURRENT_SUPERSESSION_REASON, old_result.actuator.supersession_reason
  end

  test "same provisioning operation id on historical actuator is not treated as current" do
    historical = create(
      :actuator_device,
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w",
      state: "inactive",
      current: false,
      superseded_at: Time.current
    )
    create(:actuator_device, logical_node_id: "actuator-zone2", state: "pending_observation", current: true, irrigation_line_count: 3)

    result = ActuatorProvisioningRecorder.call(
      logical_node_id: historical.logical_node_id,
      provisioning_operation_id: historical.provisioning_operation_id,
      zone_external_id: historical.zone_external_id,
      board: historical.board
    )

    assert_not result.success?
    assert_equal :conflict, result.status
    assert_equal "actuator-zone2", ActuatorDevice.current_device.logical_node_id
  end

  test "shrinking line count is rejected when existing assignments would be stranded" do
    ConnectionSetting.first.update!(irrigation_line_count: 4)
    actuator = create(:actuator_device, logical_node_id: "actuator-zone1", state: "ready", current: true, irrigation_line_count: 4)
    create(:actuator_output, actuator_device: actuator, output_index: 1, state: "assigned")
    create(:actuator_output, actuator_device: actuator, output_index: 4, state: "assigned")
    create(:node, irrigation_line: 4)
    ConnectionSetting.first.update_column(:irrigation_line_count, 2)

    result = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-002",
      zone_external_id: "zone1",
      board: "pico_w"
    )

    assert_not result.success?
    assert_equal :conflict, result.status
    assert_equal 4, actuator.reload.irrigation_line_count
  end

  test "invalid untrusted identifiers are rejected" do
    result = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator zone 1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w"
    )

    assert_not result.success?
    assert_equal :unprocessable_entity, result.status
    assert_match(/logical node id is invalid/i, result.errors.join(" "))
  end

  test "missing server-side line count is rejected" do
    ConnectionSetting.first.update_column(:irrigation_line_count, nil)

    result = ActuatorProvisioningRecorder.call(
      logical_node_id: "actuator-zone1",
      provisioning_operation_id: "provision-001",
      zone_external_id: "zone1",
      board: "pico_w"
    )

    assert_not result.success?
    assert_equal :unprocessable_entity, result.status
    assert_nil ActuatorDevice.current_device
  end

  test "database uniqueness race becomes safe conflict" do
    stub_singleton_method(ActuatorDevice, :create!, ->(*) { raise ActiveRecord::RecordNotUnique }) do
      result = ActuatorProvisioningRecorder.call(
        logical_node_id: "actuator-zone1",
        provisioning_operation_id: "provision-001",
        zone_external_id: "zone1",
        board: "pico_w"
      )

      assert_not result.success?
      assert_equal :conflict, result.status
    end
  end
end
