require "test_helper"

class ActuatorCommandTimeoutJobTest < ActiveSupport::TestCase
  test "marks a non-terminal watering event as timeout and records a fault" do
    zone = create(:zone)
    event = WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.current,
      idempotency_key: "zone1-timeout-001",
      status: "queued"
    )

    assert_difference -> { Fault.count }, 1 do
      ActuatorCommandTimeoutJob.perform_now(
        idempotency_key: event.idempotency_key,
        timeout_seconds: 75
      )
    end

    assert_equal "timeout", event.reload.status

    fault = Fault.order(:id).last
    assert_equal zone, fault.zone
    assert_equal "ACTUATOR_TIMEOUT", fault.fault_code
    assert_includes fault.detail, "75s"
    assert_includes fault.detail, event.idempotency_key
  end

  test "does nothing for an already terminal watering event" do
    zone = create(:zone)
    event = WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.current,
      idempotency_key: "zone1-timeout-002",
      status: "completed"
    )

    assert_no_difference -> { Fault.count } do
      ActuatorCommandTimeoutJob.perform_now(
        idempotency_key: event.idempotency_key,
        timeout_seconds: 75
      )
    end

    assert_equal "completed", event.reload.status
  end

  test "does nothing when the watering event cannot be found" do
    assert_no_difference -> { Fault.count } do
      ActuatorCommandTimeoutJob.perform_now(
        idempotency_key: "missing-timeout-key",
        timeout_seconds: 75
      )
    end
  end
end
