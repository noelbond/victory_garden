require "test_helper"

class ActuatorStatusIngestJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def simulate_exhausted_retries(job)
    job.exception_executions = { [StandardError].to_s => 2 }
  end

  test "ingests a valid payload" do
    zone = create(:zone, zone_id: "zone1")
    payload = {
      "zone_id" => "zone1",
      "state" => "COMPLETED",
      "timestamp" => Time.current.utc.iso8601
    }

    assert_difference -> { ActuatorStatus.count }, 1 do
      ActuatorStatusIngestJob.perform_now(payload)
    end
  end

  test "creates a fault with the resolved zone after exhausting retries on a malformed payload" do
    zone = create(:zone, zone_id: "zone1")
    payload = {
      "zone_id" => "zone1",
      "node_id" => "actuator-zone1",
      "state" => "NOT_A_REAL_STATE",
      "timestamp" => Time.current.utc.iso8601
    }

    job = ActuatorStatusIngestJob.new(payload)
    simulate_exhausted_retries(job)

    assert_difference -> { Fault.count }, 1 do
      assert_nothing_raised { job.perform_now }
    end

    fault = Fault.order(:id).last
    assert_equal zone, fault.zone
    assert_equal "actuator-zone1", fault.node_id
    assert_equal "ACTUATOR_STATUS_INGEST_FAILED", fault.fault_code
    assert_includes fault.detail, "3 attempts"
    assert_includes fault.detail, "unsupported state"
  end

  test "creates a zoneless fault when the payload references an unknown zone_id" do
    payload = {
      "zone_id" => "no-such-zone",
      "state" => "NOT_A_REAL_STATE",
      "timestamp" => Time.current.utc.iso8601
    }

    job = ActuatorStatusIngestJob.new(payload)
    simulate_exhausted_retries(job)

    assert_difference -> { Fault.count }, 1 do
      assert_nothing_raised { job.perform_now }
    end

    fault = Fault.order(:id).last
    assert_nil fault.zone
    assert_equal "ACTUATOR_STATUS_INGEST_FAILED", fault.fault_code
  end

  test "retries instead of raising or creating a fault before attempts are exhausted" do
    payload = { "zone_id" => "zone1", "state" => "NOT_A_REAL_STATE", "timestamp" => Time.current.utc.iso8601 }

    job = ActuatorStatusIngestJob.new(payload)

    assert_no_difference -> { Fault.count } do
      assert_enqueued_with(job: ActuatorStatusIngestJob) do
        assert_nothing_raised { job.perform_now }
      end
    end
  end
end
