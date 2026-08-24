require "test_helper"

class NodeDiagnosticEventIngestorTest < ActiveSupport::TestCase
  setup do
    @zone = create(:zone, zone_id: "zone1")
  end

  test "creates a fault from a valid diagnostic event" do
    fault = NodeDiagnosticEventIngestor.new(
      "node_id" => "combined-zone1",
      "zone_id" => "zone1",
      "event_code" => "BROKER_DISCOVERY_APPLIED",
      "detail" => "unreachable for 42s; discovery_no_response=2 discovery_rejected=0 last_rejected=none:0",
      "timestamp" => "2026-08-10T14:25:14Z"
    ).call

    assert fault.persisted?
    assert_equal @zone, fault.zone
    assert_equal "combined-zone1", fault.node_id
    assert_equal "BROKER_DISCOVERY_APPLIED", fault.fault_code
    assert_equal Time.iso8601("2026-08-10T14:25:14Z"), fault.recorded_at
  end

  test "raises on unknown zone_id" do
    error = assert_raises(ArgumentError) do
      NodeDiagnosticEventIngestor.new(
        "node_id" => "combined-zone1",
        "zone_id" => "no-such-zone",
        "event_code" => "BROKER_UNREACHABLE",
        "timestamp" => "2026-08-10T14:25:14Z"
      ).call
    end

    assert_match "Unknown zone_id", error.message
  end

  test "redelivering the identical event does not create a duplicate fault" do
    payload = {
      "node_id" => "combined-zone1",
      "zone_id" => "zone1",
      "event_code" => "BROKER_DISCOVERY_REJECTED",
      "detail" => "unreachable for 10s; discovery_no_response=0 discovery_rejected=1 last_rejected=10.0.0.99:1883",
      "timestamp" => "2026-08-10T14:25:14Z"
    }

    first = NodeDiagnosticEventIngestor.new(payload).call
    second = NodeDiagnosticEventIngestor.new(payload).call

    assert_equal first.id, second.id
    assert_equal 1, Fault.where(fault_code: "BROKER_DISCOVERY_REJECTED").count
  end

  test "distinct events for the same node are not deduped against each other" do
    NodeDiagnosticEventIngestor.new(
      "node_id" => "combined-zone1",
      "zone_id" => "zone1",
      "event_code" => "BROKER_DISCOVERY_NO_RESPONSE",
      "detail" => "unreachable for 30s; discovery_no_response=3 discovery_rejected=0 last_rejected=none:0",
      "timestamp" => "2026-08-10T14:00:00Z"
    ).call
    NodeDiagnosticEventIngestor.new(
      "node_id" => "combined-zone1",
      "zone_id" => "zone1",
      "event_code" => "BROKER_DISCOVERY_APPLIED",
      "detail" => "unreachable for 90s; discovery_no_response=5 discovery_rejected=0 last_rejected=none:0",
      "timestamp" => "2026-08-10T15:00:00Z"
    ).call

    assert_equal 2, Fault.where(node_id: "combined-zone1").count
  end
end
