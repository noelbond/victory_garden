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

  test "migration defaults leave existing events non-setup" do
    event = WateringEvent.create!(valid_attrs)

    assert_equal false, event.setup_validation?
    assert_equal false, event.setup_current?
    assert_nil event.setup_superseded_at
    assert_nil event.setup_invalidated_at
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

  test "blocking_start_commands excludes stale non-terminal events" do
    stale = WateringEvent.create!(valid_attrs.merge(
      idempotency_key: "zone1-we-stale",
      issued_at: 2.hours.ago,
      status: "queued"
    ))
    fresh = WateringEvent.create!(valid_attrs.merge(
      idempotency_key: "zone1-we-fresh",
      issued_at: 1.minute.ago,
      status: "running"
    ))

    assert_not_includes WateringEvent.blocking_start_commands, stale
    assert_includes WateringEvent.blocking_start_commands, fresh
  end

  test "setup validation records target fingerprint and matches current target" do
    event = setup_validation_event(zone: zone)

    assert event.setup_validation?
    assert event.setup_current?
    assert_equal "zone", event.setup_target_kind
    assert_equal zone.zone_id, event.setup_target_zone_external_id
    assert_equal zone.irrigation_line, event.setup_target_irrigation_line
    assert event.setup_target_matches?(zone: zone, node: nil)
    assert event.setup_ready_for?(zone: zone, node: nil) == false

    event.update!(status: "completed")
    assert event.setup_ready_for?(zone: zone, node: nil)
  end

  test "setup validation target mismatch is not ready" do
    event = setup_validation_event(zone: zone, status: "completed")
    zone.update!(irrigation_line: zone.irrigation_line + 10)

    assert_not event.setup_target_matches?(zone: zone, node: nil)
    assert_not event.setup_ready_for?(zone: zone, node: nil)
  end

  test "node setup validation matches only the same configured node target" do
    node = create(:node, node_id: "sensor-zone1-ch0", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 2)
    event = setup_validation_event(zone: zone, node: node, status: "completed")

    assert_equal "node", event.setup_target_kind
    assert_equal node.node_id, event.setup_target_node_id
    assert event.setup_ready_for?(zone: zone, node: node)

    other = create(:node, node_id: "sensor-zone1-ch1", zone: zone, crop_profile: zone.crop_profile, irrigation_line: 3)
    assert_not event.setup_ready_for?(zone: zone, node: other)
    assert_not event.setup_ready_for?(zone: zone, node: nil)
  end

  test "setup validation cannot be current without setup validation" do
    event = WateringEvent.new(valid_attrs.merge(setup_current: true))

    assert_not event.valid?
    assert_includes event.errors[:setup_current], "requires setup validation"
  end

  test "setup validation requires start watering and target metadata" do
    event = WateringEvent.new(valid_attrs.merge(
      command: "stop_watering",
      runtime_seconds: nil,
      setup_validation: true,
      setup_current: true
    ))

    assert_not event.valid?
    assert_includes event.errors[:command], "must be start_watering for setup validation"
    assert_includes event.errors[:setup_target_kind], "can't be blank"
    assert_includes event.errors[:setup_target_fingerprint], "can't be blank"
  end

  test "database constraint rejects two current setup validations" do
    setup_validation_event(zone: zone, idempotency_key: "zone1-current-one")

    assert_raises ActiveRecord::RecordNotUnique do
      WateringEvent.transaction(requires_new: true) do
        setup_validation_event(zone: zone, idempotency_key: "zone1-current-two")
      end
    end
  end

  test "superseded setup validation cannot satisfy readiness" do
    event = setup_validation_event(zone: zone, status: "completed")

    event.supersede_setup_validation!(reason: "retry")

    assert_equal false, event.setup_current?
    assert_not event.setup_ready_for?(zone: zone, node: nil)
    assert_equal "superseded", event.setup_lifecycle_state
  end

  private

  def setup_validation_event(zone:, node: nil, status: "queued", idempotency_key: "zone1-setup-validation")
    runtime_seconds = (node&.effective_crop_profile || zone.crop_profile).max_pulse_runtime_sec

    WateringEvent.create!(
      valid_attrs.merge(
        zone: zone,
        node_id: node&.node_id,
        runtime_seconds: runtime_seconds,
        reason: "setup_validation",
        idempotency_key: idempotency_key,
        status: status,
        setup_validation: true,
        setup_current: true
      ).merge(WateringEvent.setup_target_attributes(zone: zone, node: node, runtime_seconds: runtime_seconds))
    )
  end
end
