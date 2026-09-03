require "test_helper"

class NodeCommandTimeoutJobTest < ActiveSupport::TestCase
  test "marks a non-terminal command as timeout and records a fault" do
    zone = create(:zone)
    command = NodeCommand.create!(
      zone: zone,
      node_id: "combined-zone1-ch0",
      command: "reboot",
      command_id: "combined-zone1-ch0-timeout-001",
      status: "command_sent",
      issued_at: Time.current
    )

    assert_difference -> { Fault.count }, 1 do
      NodeCommandTimeoutJob.perform_now(command_id: command.command_id, timeout_seconds: 30)
    end

    assert_equal "timeout", command.reload.status

    fault = Fault.order(:id).last
    assert_equal zone, fault.zone
    assert_equal "combined-zone1-ch0", fault.node_id
    assert_equal "NODE_COMMAND_TIMEOUT", fault.fault_code
    assert_includes fault.detail, "30s"
    assert_includes fault.detail, command.command_id
  end

  test "describes request reading timeout as missing result" do
    zone = create(:zone)
    command = NodeCommand.create!(
      zone: zone,
      node_id: "combined-zone1-ch0",
      command: "request_reading",
      command_id: "combined-zone1-ch0-timeout-reading",
      status: "command_sent",
      issued_at: Time.current
    )

    NodeCommandTimeoutJob.perform_now(command_id: command.command_id, timeout_seconds: 30)

    fault = Fault.order(:id).last
    assert_includes fault.detail, "request_reading result"
    refute_includes fault.detail, "request_reading acknowledgement"
  end

  test "does nothing for an already acknowledged command" do
    zone = create(:zone)
    command = NodeCommand.create!(
      zone: zone,
      node_id: "combined-zone1-ch0",
      command: "reboot",
      command_id: "combined-zone1-ch0-timeout-002",
      status: "acknowledged",
      issued_at: Time.current,
      acknowledged_at: Time.current
    )

    assert_no_difference -> { Fault.count } do
      NodeCommandTimeoutJob.perform_now(command_id: command.command_id, timeout_seconds: 30)
    end

    assert_equal "acknowledged", command.reload.status
  end

  test "is idempotent when the timeout job is delivered twice after dropped results" do
    zone = create(:zone)
    command = NodeCommand.create!(
      zone: zone,
      node_id: "sensor-zone1-ch0",
      command: "request_reading",
      command_id: "packet-loss-command-b",
      status: "command_sent",
      issued_at: Time.current
    )

    assert_difference -> { Fault.where(fault_code: "NODE_COMMAND_TIMEOUT").count }, 1 do
      NodeCommandTimeoutJob.perform_now(command_id: command.command_id, timeout_seconds: 30)
      NodeCommandTimeoutJob.perform_now(command_id: command.command_id, timeout_seconds: 30)
    end

    assert_equal "timeout", command.reload.status
  end

  test "records one terminal timeout fault when every LoRa attempt is dropped" do
    zone = create(:zone)
    command = NodeCommand.create!(
      zone: zone,
      node_id: "sensor-zone1-ch0",
      command: "request_reading",
      command_id: "packet-loss-command-a-all-dropped",
      status: "command_sent",
      issued_at: Time.current
    )

    assert_difference -> { Fault.where(fault_code: "NODE_COMMAND_TIMEOUT").count }, 1 do
      NodeCommandTimeoutJob.perform_now(command_id: command.command_id, timeout_seconds: 30)
    end

    assert_equal "timeout", command.reload.status
  end

  test "is idempotent after a gateway restart loses the outstanding retry" do
    zone = create(:zone)
    command = NodeCommand.create!(
      zone: zone,
      node_id: "sensor-zone1-ch0",
      command: "request_reading",
      command_id: "gateway-restart-no-result",
      status: "command_sent",
      issued_at: Time.current
    )

    assert_difference -> { Fault.where(fault_code: "NODE_COMMAND_TIMEOUT").count }, 1 do
      NodeCommandTimeoutJob.perform_now(command_id: command.command_id, timeout_seconds: 30)
      NodeCommandTimeoutJob.perform_now(command_id: command.command_id, timeout_seconds: 30)
    end

    assert_equal "timeout", command.reload.status
  end

  test "does nothing when the command cannot be found" do
    assert_no_difference -> { Fault.count } do
      NodeCommandTimeoutJob.perform_now(command_id: "missing-command", timeout_seconds: 30)
    end
  end
end
