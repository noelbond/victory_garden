require "test_helper"

class NodeCommunicationTransportTest < ActiveSupport::TestCase
  test "defaults communication transport to wifi" do
    node = Node.create!(node_id: "node-transport-default", last_seen_at: Time.current)

    assert_equal "wifi", node.communication_transport
    assert node.wifi_transport?
    refute node.lora_transport?
    refute node.auto_transport?
  end

  test "accepts supported communication transports" do
    Node::COMMUNICATION_TRANSPORTS.each do |transport|
      node = Node.new(
        node_id: "node-transport-#{transport}",
        last_seen_at: Time.current,
        communication_transport: transport
      )

      assert node.valid?, "#{transport.inspect} should be valid"
    end
  end

  test "rejects unsupported communication transport" do
    node = Node.new(
      node_id: "node-transport-bad",
      last_seen_at: Time.current,
      communication_transport: "bluetooth"
    )

    refute node.valid?
    assert_includes node.errors[:communication_transport], "is not included in the list"
  end
end
