require "test_helper"

class ActuatorStatusIngestorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    @crop = create(:crop_profile, crop_id: "tomato-loop")
    @zone = create(:zone, zone_id: "zone1", name: "Zone 1", crop_profile: @crop)
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "completed actuator status marks event completed and schedules a reread" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-001",
      status: "queued"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "COMPLETED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key,
      "actual_runtime_seconds" => 44
    }

    freeze_time do
      assert_enqueued_with(
        job: RequestReadingJob,
        args: [{ zone_id: "zone1", command_id: "zone1-run-001-reread" }],
        at: 5.minutes.from_now
      ) do
        ActuatorStatusIngestor.new(payload).call
      end
    end

    assert_equal "completed", event.reload.status
    assert_equal 0, Fault.count
  end

  test "fault actuator status marks the event fault and records a fault" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-002",
      status: "running"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "FAULT",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key,
      "fault_code" => "NO_FLOW",
      "fault_detail" => "Pump reported no flow"
    }

    assert_no_enqueued_jobs only: RequestReadingJob do
      ActuatorStatusIngestor.new(payload).call
    end

    assert_equal "fault", event.reload.status
    fault = Fault.order(:id).last
    assert_equal @zone, fault.zone
    assert_equal "NO_FLOW", fault.fault_code
    assert_equal "Pump reported no flow", fault.detail
  end

  test "stopped actuator status marks the event stopped without scheduling reread" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "stop_watering",
      runtime_seconds: nil,
      reason: "manual_stop",
      issued_at: Time.current,
      idempotency_key: "zone1-stop-001",
      status: "running"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "STOPPED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key,
      "actual_runtime_seconds" => 12
    }

    assert_no_enqueued_jobs only: RequestReadingJob do
      ActuatorStatusIngestor.new(payload).call
    end

    assert_equal "stopped", event.reload.status
    assert_equal 0, Fault.count
  end

  test "stopped stop command also marks the active start event stopped" do
    started = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: 10.seconds.ago,
      idempotency_key: "zone1-run-006",
      status: "running"
    )
    stopped = WateringEvent.create!(
      zone: @zone,
      command: "stop_watering",
      runtime_seconds: nil,
      reason: "manual_stop",
      issued_at: Time.current,
      idempotency_key: "zone1-stop-006",
      status: "command_sent"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "STOPPED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => stopped.idempotency_key,
      "actual_runtime_seconds" => 3
    }

    assert_no_enqueued_jobs only: RequestReadingJob do
      ActuatorStatusIngestor.new(payload).call
    end

    assert_equal "stopped", stopped.reload.status
    assert_equal "stopped", started.reload.status
  end

  test "completed status does not schedule reread when daily runtime cap is already met" do
    WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: @zone.crop_profile.daily_max_runtime_sec,
      reason: "earlier_run",
      issued_at: Time.current.beginning_of_day + 1.hour,
      idempotency_key: "zone1-run-cap",
      status: "completed"
    )

    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-003",
      status: "running"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "COMPLETED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key
    }

    assert_no_enqueued_jobs only: RequestReadingJob do
      ActuatorStatusIngestor.new(payload).call
    end

    assert_equal "completed", event.reload.status
  end

  test "daily runtime cap ignores non-completed events" do
    WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: @zone.crop_profile.daily_max_runtime_sec,
      reason: "earlier_run",
      issued_at: Time.current.beginning_of_day + 1.hour,
      idempotency_key: "zone1-run-cap-fault",
      status: "fault"
    )

    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-cap-after-fault",
      status: "running"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "COMPLETED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key
    }

    freeze_time do
      assert_enqueued_with(job: RequestReadingJob) do
        ActuatorStatusIngestor.new(payload).call
      end
    end

    assert_equal "completed", event.reload.status
  end

  test "duplicate completed status is idempotent" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-004",
      status: "queued"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "COMPLETED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key,
      "actual_runtime_seconds" => 45
    }

    freeze_time do
      assert_enqueued_jobs 1, only: RequestReadingJob do
        ActuatorStatusIngestor.new(payload).call
        ActuatorStatusIngestor.new(payload).call
      end
    end

    assert_equal 1, ActuatorStatus.where(zone: @zone, idempotency_key: event.idempotency_key, state: "COMPLETED").count
    assert_equal "completed", event.reload.status
  end

  test "acknowledged actuator status creates status record and marks event acknowledged" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-007",
      status: "command_sent"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "ACKNOWLEDGED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key
    }

    assert_no_enqueued_jobs only: RequestReadingJob do
      ActuatorStatusIngestor.new(payload).call
    end

    assert_equal "acknowledged", event.reload.status
    assert ActuatorStatus.exists?(zone: @zone, idempotency_key: event.idempotency_key, state: "ACKNOWLEDGED")
  end

  test "running actuator status creates status record and marks event running" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-008",
      status: "acknowledged"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "RUNNING",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key
    }

    assert_no_enqueued_jobs only: RequestReadingJob do
      ActuatorStatusIngestor.new(payload).call
    end

    assert_equal "running", event.reload.status
    assert ActuatorStatus.exists?(zone: @zone, idempotency_key: event.idempotency_key, state: "RUNNING")
  end

  test "raises for an unknown zone_id" do
    payload = {
      "zone_id" => "does-not-exist",
      "state" => "COMPLETED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => "orphan-key-001"
    }

    error = assert_raises(ArgumentError) { ActuatorStatusIngestor.new(payload).call }

    assert_match "Unknown zone_id", error.message
  end

  test "creates status record even when no matching watering event exists" do
    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "COMPLETED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => "orphan-key-002"
    }

    assert_difference -> { ActuatorStatus.count }, 1 do
      ActuatorStatusIngestor.new(payload).call
    end

    assert_equal 0, WateringEvent.count
  end

  test "duplicate fault status does not create duplicate faults" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-005",
      status: "running"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "FAULT",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key,
      "fault_code" => "NO_FLOW",
      "fault_detail" => "Pump reported no flow"
    }

    ActuatorStatusIngestor.new(payload).call
    ActuatorStatusIngestor.new(payload).call

    assert_equal 1, ActuatorStatus.where(zone: @zone, idempotency_key: event.idempotency_key, state: "FAULT").count
    assert_equal 1, Fault.where(zone: @zone, fault_code: "NO_FLOW").count
    assert_equal "fault", event.reload.status
  end

  test "repeated unresolved fault does not create a second fault row" do
    first_event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-009",
      status: "running"
    )
    second_event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: 1.minute.from_now,
      idempotency_key: "zone1-run-009b",
      status: "running"
    )

    first_payload = {
      "zone_id" => @zone.zone_id,
      "state" => "FAULT",
      "timestamp" => 2.minutes.ago.iso8601,
      "idempotency_key" => first_event.idempotency_key,
      "fault_code" => "NO_FLOW",
      "fault_detail" => "Pump reported no flow"
    }
    second_payload = first_payload.merge(
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => second_event.idempotency_key
    )

    ActuatorStatusIngestor.new(first_payload).call
    ActuatorStatusIngestor.new(second_payload).call

    assert_equal 2, ActuatorStatus.where(zone: @zone, state: "FAULT").count
    assert_equal 1, Fault.where(zone: @zone, fault_code: "NO_FLOW", detail: "Pump reported no flow", resolved_at: nil).count
  end

  test "out of order acknowledged status does not roll event back from completed" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-010",
      status: "completed"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "ACKNOWLEDGED",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key
    }

    ActuatorStatusIngestor.new(payload).call

    assert_equal "completed", event.reload.status
    assert ActuatorStatus.exists?(zone: @zone, idempotency_key: event.idempotency_key, state: "ACKNOWLEDGED")
  end

  test "status create rolls back if fault persistence fails" do
    event = WateringEvent.create!(
      zone: @zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "below_dry_threshold",
      issued_at: Time.current,
      idempotency_key: "zone1-run-011",
      status: "running"
    )

    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "FAULT",
      "timestamp" => Time.current.iso8601,
      "idempotency_key" => event.idempotency_key,
      "fault_code" => "NO_FLOW",
      "fault_detail" => "Pump reported no flow"
    }

    error = nil
    original_find_by = Fault.method(:find_by)
    original_create = Fault.method(:create!)
    Fault.define_singleton_method(:find_by) { |*_args, **_kwargs| nil }
    Fault.define_singleton_method(:create!) { |*_args, **_kwargs| raise ActiveRecord::ActiveRecordError, "boom" }

    error = assert_raises(ActiveRecord::ActiveRecordError) { ActuatorStatusIngestor.new(payload).call }
  ensure
    Fault.define_singleton_method(:find_by, original_find_by)
    Fault.define_singleton_method(:create!, original_create)
    if error
      assert_equal "boom", error.message
      assert_equal "running", event.reload.status
      assert_equal 0, ActuatorStatus.where(zone: @zone, idempotency_key: event.idempotency_key, state: "FAULT").count
      assert_equal 0, Fault.where(zone: @zone, fault_code: "NO_FLOW").count
    end
  end

  test "rejects payloads with unknown keys at ingestor boundary" do
    payload = {
      "zone_id" => @zone.zone_id,
      "state" => "COMPLETED",
      "timestamp" => Time.current.iso8601,
      "unexpected" => "nope"
    }

    error = assert_raises(ArgumentError) do
      ActuatorStatusIngestor.new(payload).call
    end

    assert_match "unknown keys", error.message
    assert_equal 0, ActuatorStatus.count
    assert_equal 0, Fault.count
  end
end
