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
      assert_equal "pico-w-zone1", normalized["node_id"]
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

    test "rejects payload missing required keys" do
      PayloadContracts::NodeState::REQUIRED_KEYS.each do |key|
        payload = load_fixture("node-state-v1.json").except(key)

        error = assert_raises(ArgumentError) { NodeState.normalize!(payload) }

        assert_match("missing required key: #{key}", error.message)
      end
    end

    test "rejects unsupported schema_version" do
      payload = load_fixture("node-state-v1.json").merge("schema_version" => "node-state/v99")

      error = assert_raises(ArgumentError) { NodeState.normalize!(payload) }

      assert_match("unsupported schema_version", error.message)
    end

    test "rejects invalid iso8601 timestamp" do
      payload = load_fixture("node-state-v1.json").merge("timestamp" => "not-a-date")

      assert_raises(ArgumentError) { NodeState.normalize!(payload) }
    end

    test "rejects out-of-range moisture_percent" do
      payload = load_fixture("node-state-v1.json").merge("moisture_percent" => 101.0)

      error = assert_raises(ArgumentError) { NodeState.normalize!(payload) }

      assert_match("moisture_percent out of range", error.message)
    end

    test "rejects out-of-range wifi_rssi" do
      payload = load_fixture("node-state-v1.json").merge("wifi_rssi" => -131)

      error = assert_raises(ArgumentError) { NodeState.normalize!(payload) }

      assert_match("wifi_rssi out of range", error.message)
    end

    test "rejects negative uptime_seconds" do
      payload = load_fixture("node-state-v1.json").merge("uptime_seconds" => -1)

      error = assert_raises(ArgumentError) { NodeState.normalize!(payload) }

      assert_match("uptime_seconds out of range", error.message)
    end

    test "rejects non-hash payload" do
      error = assert_raises(ArgumentError) { NodeState.normalize!([1, 2, 3]) }

      assert_match("payload must be a JSON object", error.message)
    end
  end
end
