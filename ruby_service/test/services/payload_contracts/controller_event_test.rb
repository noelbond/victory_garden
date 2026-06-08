require "test_helper"

module PayloadContracts
  class ControllerEventTest < ActiveSupport::TestCase
    test "accepts canonical controller event payload" do
      normalized = ControllerEvent.normalize!(
        "zone_id" => "zone1",
        "timestamp" => "2026-03-31T20:00:00Z",
        "action" => "water",
        "runtime_seconds" => 45,
        "runtime_seconds_today" => 45,
        "idempotency_key" => "zone1-20260331T200000Z-abcd1234",
        "reason" => "below_dry_threshold",
        "moisture_percent" => 21.5,
        "valid_sensor_count" => 1,
        "expected_sensor_count" => 1,
        "valid_node_ids" => ["pico-w-zone1"]
      )

      assert_equal "water", normalized["action"]
      assert_instance_of Time, normalized["timestamp"]
      assert_equal 45, normalized["runtime_seconds"]
      assert_equal ["pico-w-zone1"], normalized["valid_node_ids"]
    end

    test "rejects unknown keys" do
      error = assert_raises(ArgumentError) do
        ControllerEvent.normalize!(
          "zone_id" => "zone1",
          "timestamp" => "2026-03-31T20:00:00Z",
          "action" => "water",
          "unexpected" => "nope"
        )
      end

      assert_match("unknown keys", error.message)
    end

    test "rejects out-of-range moisture_percent" do
      error = assert_raises(ArgumentError) do
        ControllerEvent.normalize!(
          "zone_id" => "zone1",
          "timestamp" => "2026-03-31T20:00:00Z",
          "action" => "water",
          "moisture_percent" => 101.0
        )
      end

      assert_match("moisture_percent out of range", error.message)
    end

    test "rejects invalid valid_node_ids" do
      error = assert_raises(ArgumentError) do
        ControllerEvent.normalize!(
          "zone_id" => "zone1",
          "timestamp" => "2026-03-31T20:00:00Z",
          "action" => "water",
          "valid_node_ids" => "pico-w-zone1"
        )
      end

      assert_match("invalid valid_node_ids", error.message)
    end
  end
end
