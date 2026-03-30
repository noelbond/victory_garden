require "test_helper"

module PayloadContracts
  class NodeStateTest < ActiveSupport::TestCase
    def load_fixture(name)
      JSON.parse(File.read(Rails.root.join("..", "contracts", "examples", name)))
    end

    test "accepts canonical node-state fixture" do
      payload = load_fixture("node-state-v1.json")

      normalized = NodeState.normalize!(payload)

      assert_equal "node-state/v1", normalized["schema_version"]
      assert_equal "mkr1010-zone1", normalized["node_id"]
      assert_equal "zone1", normalized["zone_id"]
      assert_instance_of Time, normalized["recorded_at"]
    end

    test "accepts legacy rssi alias" do
      payload = load_fixture("node-state-legacy-rssi.json")

      normalized = NodeState.normalize!(payload)

      assert_equal(-61, normalized["wifi_rssi"])
      assert_not normalized.key?("rssi")
    end

    test "accepts partial payload when required keys are present" do
      payload = load_fixture("node-state-partial.json")

      normalized = NodeState.normalize!(payload)

      assert_equal "partial-zone1", normalized["node_id"]
      assert_nil normalized["moisture_percent"]
    end

    test "accepts optional metadata nulls" do
      payload = load_fixture("node-state-optional-nulls.json")

      normalized = NodeState.normalize!(payload)

      assert_nil normalized["battery_voltage"]
      assert_nil normalized["health"]
    end

    test "rejects unknown keys" do
      payload = load_fixture("node-state-v1.json")
      payload["unexpected"] = "nope"

      error = assert_raises(ArgumentError) { NodeState.normalize!(payload) }

      assert_match("unknown keys", error.message)
    end
  end
end

