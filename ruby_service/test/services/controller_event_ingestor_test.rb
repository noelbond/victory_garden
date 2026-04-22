require "test_helper"

class ControllerEventIngestorTest < ActiveSupport::TestCase
  setup do
    @zone = create(:zone, zone_id: "zone1")
  end

  test "creates watering event for automatic water action" do
    payload = {
      "zone_id" => "zone1",
      "timestamp" => "2026-03-31T20:00:00Z",
      "action" => "water",
      "runtime_seconds" => 45,
      "runtime_seconds_today" => 45,
      "idempotency_key" => "zone1-20260331T200000Z-abcd1234",
      "reason" => "below_dry_threshold"
    }

    event = ControllerEventIngestor.new(payload).call

    assert_equal "start_watering", event.command
    assert_equal 45, event.runtime_seconds
    assert_equal "below_dry_threshold", event.reason
    assert_equal "queued", event.status
    assert_equal @zone, event.zone
  end

  test "ignores non watering controller events" do
    payload = {
      "zone_id" => "zone1",
      "timestamp" => "2026-03-31T20:00:00Z",
      "action" => "none",
      "runtime_seconds" => 0
    }

    assert_nil ControllerEventIngestor.new(payload).call
    assert_equal 0, WateringEvent.count
  end

  test "is idempotent by idempotency key" do
    payload = {
      "zone_id" => "zone1",
      "timestamp" => "2026-03-31T20:00:00Z",
      "action" => "water",
      "runtime_seconds" => 45,
      "runtime_seconds_today" => 45,
      "idempotency_key" => "zone1-20260331T200000Z-abcd1234",
      "reason" => "below_dry_threshold"
    }

    first = ControllerEventIngestor.new(payload).call
    second = ControllerEventIngestor.new(payload).call

    assert_equal first.id, second.id
    assert_equal 1, WateringEvent.where(idempotency_key: payload["idempotency_key"]).count
  end

  test "rejects missing runtime_seconds" do
    payload = {
      "zone_id" => "zone1",
      "timestamp" => "2026-03-31T20:00:00Z",
      "action" => "water",
      "idempotency_key" => "zone1-20260331T200000Z-abcd1234"
    }

    error = assert_raises(ArgumentError) do
      ControllerEventIngestor.new(payload).call
    end

    assert_match "Invalid runtime_seconds", error.message
    assert_equal 0, WateringEvent.count
  end

  test "rejects non-positive runtime_seconds" do
    payload = {
      "zone_id" => "zone1",
      "timestamp" => "2026-03-31T20:00:00Z",
      "action" => "water",
      "runtime_seconds" => 0,
      "idempotency_key" => "zone1-20260331T200000Z-abcd1234"
    }

    error = assert_raises(ArgumentError) do
      ControllerEventIngestor.new(payload).call
    end

    assert_match "Invalid runtime_seconds", error.message
    assert_equal 0, WateringEvent.count
  end

  test "rejects unknown zone id" do
    payload = {
      "zone_id" => "missing-zone",
      "timestamp" => "2026-03-31T20:00:00Z",
      "action" => "water",
      "runtime_seconds" => 45,
      "idempotency_key" => "missing-zone-20260331T200000Z-abcd1234"
    }

    error = assert_raises(ArgumentError) do
      ControllerEventIngestor.new(payload).call
    end

    assert_match "Unknown zone_id", error.message
  end

  test "rejects non-integer runtime_seconds values" do
    payload = {
      "zone_id" => "zone1",
      "timestamp" => "2026-03-31T20:00:00Z",
      "action" => "water",
      "runtime_seconds" => "forty-five",
      "idempotency_key" => "zone1-20260331T200000Z-abcd1234"
    }

    error = assert_raises(ArgumentError) do
      ControllerEventIngestor.new(payload).call
    end

    assert_match "Invalid runtime_seconds", error.message
  end
end
