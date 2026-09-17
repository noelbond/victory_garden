require "test_helper"

module PayloadContracts
  class ActuatorStatusTest < ActiveSupport::TestCase
    test "accepts canonical actuator status payload" do
      normalized = ActuatorStatus.normalize!(
        "zone_id" => "zone1",
        "state" => "COMPLETED",
        "timestamp" => "2026-05-11T14:25:14Z",
        "idempotency_key" => "zone1-20260511T142428Z-800f0f79",
        "affected_run_idempotency_key" => "zone1-20260511T142000Z-start",
        "actual_runtime_seconds" => 45
      )

      assert_equal "COMPLETED", normalized["state"]
      assert_instance_of Time, normalized["timestamp"]
      assert_equal 45, normalized["actual_runtime_seconds"]
      assert_equal "zone1-20260511T142000Z-start", normalized["affected_run_idempotency_key"]
    end

    test "accepts a null affected run idempotency key" do
      normalized = ActuatorStatus.normalize!(
        "zone_id" => "zone1",
        "state" => "STOPPED",
        "timestamp" => "2026-05-11T14:25:14Z",
        "idempotency_key" => "zone1-stop-001",
        "affected_run_idempotency_key" => nil
      )

      assert_nil normalized["affected_run_idempotency_key"]
    end

    test "rejects unknown keys" do
      error = assert_raises(ArgumentError) do
        ActuatorStatus.normalize!(
          "zone_id" => "zone1",
          "state" => "COMPLETED",
          "timestamp" => "2026-05-11T14:25:14Z",
          "unexpected" => "nope"
        )
      end

      assert_match("unknown keys", error.message)
    end

    test "rejects unsupported state" do
      error = assert_raises(ArgumentError) do
        ActuatorStatus.normalize!(
          "zone_id" => "zone1",
          "state" => "PAUSED",
          "timestamp" => "2026-05-11T14:25:14Z"
        )
      end

      assert_match("unsupported state", error.message)
    end

    test "rejects out-of-range runtime" do
      error = assert_raises(ArgumentError) do
        ActuatorStatus.normalize!(
          "zone_id" => "zone1",
          "state" => "COMPLETED",
          "timestamp" => "2026-05-11T14:25:14Z",
          "actual_runtime_seconds" => 3601
        )
      end

      assert_match("actual_runtime_seconds out of range", error.message)
    end

    test "rejects an overlong affected run idempotency key" do
      error = assert_raises(ArgumentError) do
        ActuatorStatus.normalize!(
          "zone_id" => "zone1",
          "state" => "STOPPED",
          "timestamp" => "2026-05-11T14:25:14Z",
          "affected_run_idempotency_key" => "x" * 301
        )
      end

      assert_match("affected_run_idempotency_key", error.message)
    end
  end
end
