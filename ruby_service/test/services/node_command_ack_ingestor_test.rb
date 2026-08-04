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

  test "does nothing for an unknown command_id" do
    payload = { "node_id" => "combined-zone1", "command_id" => "unknown-command", "status" => "acknowledged" }

    assert_nil NodeCommandAckIngestor.new(payload).call
  end
end
