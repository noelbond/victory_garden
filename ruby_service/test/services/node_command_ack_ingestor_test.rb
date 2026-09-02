require "test_helper"

class NodeCommandAckIngestorTest < ActiveSupport::TestCase
  setup do
    @zone = create(:zone, zone_id: "zone1")
    @command = NodeCommand.create!(
      zone: @zone,
      node_id: "combined-zone1-ch0",
      command: "reboot",
      command_id: "combined-zone1-ch0-20260804T000000Z-reboot",
      status: "command_sent",
      issued_at: Time.current
    )
  end

  test "marks a command_sent command as acknowledged" do
    payload = {
      "schema_version" => "node-command-ack/v1",
      "zone_id" => "zone1",
      "node_id" => "combined-zone1",
      "command" => "reboot",
      "command_id" => @command.command_id,
      "status" => "acknowledged"
    }

    result = NodeCommandAckIngestor.new(payload).call

    assert_equal @command, result
    assert_equal "acknowledged", @command.reload.status
    assert @command.acknowledged_at.present?
  end

  test "does nothing for an ack that arrives after the command already timed out" do
    @command.update!(status: "timeout")
    payload = {
      "node_id" => "combined-zone1",
      "command_id" => @command.command_id,
      "status" => "acknowledged"
    }

    NodeCommandAckIngestor.new(payload).call

    assert_equal "timeout", @command.reload.status
  end

  test "marks a failed ack as timed out" do
    payload = {
      "node_id" => "combined-zone1",
      "command_id" => @command.command_id,
      "status" => "failed",
      "error" => "sensor_read_failed"
    }

    result = nil
    assert_difference -> { Fault.where(fault_code: "NODE_COMMAND_TIMEOUT").count }, 1 do
      result = NodeCommandAckIngestor.new(payload).call
    end

    assert_equal @command, result
    assert_equal "timeout", @command.reload.status
    assert_nil @command.acknowledged_at
    fault = Fault.order(:id).last
    assert_equal @zone, fault.zone
    assert_equal @command.node_id, fault.node_id
    assert_includes fault.detail, "sensor_read_failed"
  end

  test "marks a rejected ack as timed out" do
    payload = {
      "node_id" => "combined-zone1",
      "command_id" => @command.command_id,
      "status" => "rejected",
      "error" => "unsupported_command"
    }

    assert_difference -> { Fault.where(fault_code: "NODE_COMMAND_TIMEOUT").count }, 1 do
      NodeCommandAckIngestor.new(payload).call
    end

    assert_equal "timeout", @command.reload.status
    assert_nil @command.acknowledged_at
  end

  test "does not mark duplicate ack as successful" do
    payload = {
      "node_id" => "combined-zone1",
      "command_id" => @command.command_id,
      "status" => "duplicate",
      "error" => "already_seen"
    }

    result = NodeCommandAckIngestor.new(payload).call

    assert_equal @command, result
    assert_equal "command_sent", @command.reload.status
    assert_nil @command.acknowledged_at
  end

  test "does not record a failure fault for duplicate ack" do
    payload = {
      "node_id" => "combined-zone1",
      "command_id" => @command.command_id,
      "status" => "duplicate",
      "error" => "already_seen"
    }

    assert_no_difference -> { Fault.count } do
      NodeCommandAckIngestor.new(payload).call
    end
  end

  test "does nothing for an unknown command_id" do
    payload = { "node_id" => "combined-zone1", "command_id" => "unknown-command", "status" => "acknowledged" }

    assert_nil NodeCommandAckIngestor.new(payload).call
  end
end
