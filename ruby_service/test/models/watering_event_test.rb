require "test_helper"

class WateringEventTest < ActiveSupport::TestCase
  def zone
    @zone ||= create(:zone)
  end

  def valid_attrs
    {
      zone: zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-we-test-001",
      status: "queued"
    }
  end

  test "valid with all required fields" do
    assert WateringEvent.new(valid_attrs).valid?
  end

  test "requires command" do
    event = WateringEvent.new(valid_attrs.merge(command: nil))
    assert_not event.valid?
    assert_includes event.errors[:command], "can't be blank"
  end

  test "requires issued_at" do
    event = WateringEvent.new(valid_attrs.merge(issued_at: nil))
    assert_not event.valid?
    assert_includes event.errors[:issued_at], "can't be blank"
  end

  test "requires idempotency_key" do
    event = WateringEvent.new(valid_attrs.merge(idempotency_key: nil))
    assert_not event.valid?
    assert_includes event.errors[:idempotency_key], "can't be blank"
  end

  test "rejects unrecognized status" do
    event = WateringEvent.new(valid_attrs.merge(status: "pending"))
    assert_not event.valid?
    assert_includes event.errors[:status], "is not included in the list"
  end

  test "all recognized statuses are valid" do
    WateringEvent::STATUSES.each do |status|
      event = WateringEvent.new(valid_attrs.merge(
        idempotency_key: "zone1-we-status-#{status}",
        status: status
      ))
      assert event.valid?, "expected status #{status.inspect} to be valid"
    end
  end

  test "rejects negative runtime_seconds" do
    event = WateringEvent.new(valid_attrs.merge(runtime_seconds: -1))
    assert_not event.valid?
    assert_includes event.errors[:runtime_seconds], "must be greater than or equal to 0"
  end

  test "stop_watering with runtime_seconds present is invalid" do
    event = WateringEvent.new(valid_attrs.merge(command: "stop_watering", runtime_seconds: 30))
    assert_not event.valid?
    assert_includes event.errors[:runtime_seconds], "must be blank for stop_watering"
  end

  test "stop_watering with nil runtime_seconds is valid" do
    event = WateringEvent.new(valid_attrs.merge(command: "stop_watering", runtime_seconds: nil))
    assert event.valid?
  end

  test "start_watering with runtime_seconds present is valid" do
    event = WateringEvent.new(valid_attrs.merge(command: "start_watering", runtime_seconds: 60))
    assert event.valid?
  end
end
