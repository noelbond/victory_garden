require "test_helper"

module PayloadContracts
  class NodeDiagnosticEventTest < ActiveSupport::TestCase
    test "accepts canonical node diagnostic event payload" do
      normalized = NodeDiagnosticEvent.normalize!(
        "node_id" => "combined-zone1",
        "zone_id" => "zone1",
        "event_code" => "BROKER_DISCOVERY_APPLIED",
        "detail" => "unreachable for 42s; discovery_no_response=2 discovery_rejected=0 last_rejected=none:0",
        "timestamp" => "2026-08-10T14:25:14Z"
      )

      assert_equal "BROKER_DISCOVERY_APPLIED", normalized["event_code"]
      assert_instance_of Time, normalized["timestamp"]
    end

    test "rejects unknown keys" do
      error = assert_raises(ArgumentError) do
        NodeDiagnosticEvent.normalize!(
          "node_id" => "combined-zone1",
          "zone_id" => "zone1",
          "event_code" => "BROKER_UNREACHABLE",
          "timestamp" => "2026-08-10T14:25:14Z",
          "unexpected" => "nope"
        )
      end

      assert_match("unknown keys", error.message)
    end

    test "rejects unsupported event_code" do
      error = assert_raises(ArgumentError) do
        NodeDiagnosticEvent.normalize!(
          "node_id" => "combined-zone1",
          "zone_id" => "zone1",
          "event_code" => "SOMETHING_MADE_UP",
          "timestamp" => "2026-08-10T14:25:14Z"
        )
      end

      assert_match("unsupported event_code", error.message)
    end

    test "rejects missing required key" do
      error = assert_raises(ArgumentError) do
        NodeDiagnosticEvent.normalize!(
          "zone_id" => "zone1",
          "event_code" => "BROKER_UNREACHABLE",
          "timestamp" => "2026-08-10T14:25:14Z"
        )
      end

      assert_match("missing required key: node_id", error.message)
    end

    test "substitutes server time for the NTP-not-synced 1970 sentinel timestamp" do
      travel_to Time.utc(2026, 8, 10, 12, 0, 0) do
        normalized = NodeDiagnosticEvent.normalize!(
          "node_id" => "combined-zone1",
          "zone_id" => "zone1",
          "event_code" => "BROKER_DISCOVERY_APPLIED",
          "timestamp" => "1970-01-01T00:04:12Z"
        )

        assert_equal Time.utc(2026, 8, 10, 12, 0, 0), normalized["timestamp"]
      end
    end

    test "rejects mismatched schema_version" do
      error = assert_raises(ArgumentError) do
        NodeDiagnosticEvent.normalize!(
          "node_id" => "combined-zone1",
          "zone_id" => "zone1",
          "event_code" => "BROKER_UNREACHABLE",
          "timestamp" => "2026-08-10T14:25:14Z",
          "schema_version" => "node-diagnostic-event/v2"
        )
      end

      assert_match("unsupported schema_version", error.message)
    end
  end
end
