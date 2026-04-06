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
end
