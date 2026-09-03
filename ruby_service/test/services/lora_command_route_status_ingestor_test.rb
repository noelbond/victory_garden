require "test_helper"

class LoraCommandRouteStatusIngestorTest < ActiveSupport::TestCase
  setup do
    @zone = create(:zone, zone_id: "zone1")
    @node = Node.create!(
      node_id: "sensor-zone1-ch0",
      zone: @zone,
      last_seen_at: Time.current,
      communication_transport: "lora"
    )
  end

  test "failed route event marks matching command timed out and records fault" do
    command = NodeCommand.create!(
      zone: @zone,
      node_id: @node.node_id,
      command: "request_reading",
      command_id: "cmd-001",
      status: "command_sent",
      issued_at: Time.current
    )

    assert_difference -> { Fault.count }, 1 do
      LoraCommandRouteStatusIngestor.new(failed_payload(message_id: command.command_id)).call
    end

    assert_equal "timeout", command.reload.status
    fault = Fault.order(:id).last
    assert_equal @zone, fault.zone
    assert_equal @node.node_id, fault.node_id
    assert_equal "LORA_COMMAND_ROUTE_FAILED", fault.fault_code
    assert_includes fault.detail, "request_reading"
    assert_includes fault.detail, "cmd-001"
    assert_includes fault.detail, "serial_disconnected"
  end

  test "duplicate failed route event creates only one fault" do
    command = NodeCommand.create!(
      zone: @zone,
      node_id: @node.node_id,
      command: "request_reading",
      command_id: "cmd-duplicate-failure",
      status: "command_sent",
      issued_at: Time.current
    )

    assert_difference -> { Fault.where(fault_code: "LORA_COMMAND_ROUTE_FAILED").count }, 1 do
      2.times do
        LoraCommandRouteStatusIngestor.new(failed_payload(message_id: command.command_id)).call
      end
    end

    assert_equal "timeout", command.reload.status
  end

  test "failed route event for another target does not transition matching command" do
    command = NodeCommand.create!(
      zone: @zone,
      node_id: @node.node_id,
      command: "request_reading",
      command_id: "cmd-wrong-target",
      status: "command_sent",
      issued_at: Time.current
    )

    assert_no_difference -> { Fault.count } do
      LoraCommandRouteStatusIngestor.new(
        failed_payload(message_id: command.command_id, target_node_id: "another-node")
      ).call
    end

    assert_equal "command_sent", command.reload.status
  end

  test "routed event does not change command or create fault" do
    command = NodeCommand.create!(
      zone: @zone,
      node_id: @node.node_id,
      command: "request_reading",
      command_id: "cmd-002",
      status: "command_sent",
      issued_at: Time.current
    )

    assert_no_difference -> { Fault.count } do
      LoraCommandRouteStatusIngestor.new(
        failed_payload(message_id: command.command_id).merge("status" => "routed", "reason" => nil)
      ).call
    end

    assert_equal "command_sent", command.reload.status
  end

  test "failed route event does not roll acknowledged command back" do
    command = NodeCommand.create!(
      zone: @zone,
      node_id: @node.node_id,
      command: "request_reading",
      command_id: "cmd-003",
      status: "acknowledged",
      issued_at: Time.current,
      acknowledged_at: Time.current
    )

    assert_no_difference -> { Fault.count } do
      LoraCommandRouteStatusIngestor.new(failed_payload(message_id: command.command_id)).call
    end

    assert_equal "acknowledged", command.reload.status
  end

  test "failed route event without matching command still records a node-scoped fault" do
    assert_difference -> { Fault.count }, 1 do
      LoraCommandRouteStatusIngestor.new(failed_payload(message_id: "missing-cmd")).call
    end

    fault = Fault.order(:id).last
    assert_equal @zone, fault.zone
    assert_equal @node.node_id, fault.node_id
    assert_equal "LORA_COMMAND_ROUTE_FAILED", fault.fault_code
    assert_includes fault.detail, "unknown command missing-cmd"
  end

  test "rejects malformed route status payloads" do
    error = assert_raises(ArgumentError) do
      LoraCommandRouteStatusIngestor.new(failed_payload.merge("schema_version" => "wrong/v1")).call
    end

    assert_includes error.message, "Unsupported schema_version"
  end

  private

  def failed_payload(overrides = {})
    {
      "schema_version" => "lora-command-route-status/v1",
      "timestamp" => "2026-09-01T15:00:00Z",
      "status" => "failed",
      "reason" => "serial_disconnected",
      "target_node_id" => @node.node_id,
      "message_id" => "cmd-001",
      "topic" => "greenhouse/nodes/#{@node.node_id}/lora/command"
    }.merge(overrides)
  end
end
