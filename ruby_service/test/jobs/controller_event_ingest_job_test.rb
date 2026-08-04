require "test_helper"

class ControllerEventIngestJobTest < ActiveSupport::TestCase
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

  test "ingests a valid watering event" do
    create(:zone, zone_id: "zone1")
    payload = {
      "zone_id" => "zone1",
      "timestamp" => Time.current.utc.iso8601,
      "action" => "water",
      "idempotency_key" => "zone1-cmd-1",
      "runtime_seconds" => 45
    }

    assert_difference -> { WateringEvent.count }, 1 do
      ControllerEventIngestJob.perform_now(payload)
    end
  end

  test "creates a fault with the resolved zone after exhausting retries on a malformed payload" do
    zone = create(:zone, zone_id: "zone1")
    payload = {
      "zone_id" => "zone1",
      "node_id" => "sensor-zone1",
      "action" => "water"
      # missing required "timestamp" key
    }

    job = ControllerEventIngestJob.new(payload)
    simulate_exhausted_retries(job)

    assert_difference -> { Fault.count }, 1 do
      assert_nothing_raised { job.perform_now }
    end

    fault = Fault.order(:id).last
    assert_equal zone, fault.zone
    assert_equal "sensor-zone1", fault.node_id
    assert_equal "CONTROLLER_EVENT_INGEST_FAILED", fault.fault_code
    assert_includes fault.detail, "3 attempts"
    assert_includes fault.detail, "missing required key"
  end

  test "creates a zoneless fault when the payload references an unknown zone_id" do
    payload = {
      "zone_id" => "no-such-zone",
      "action" => "water"
      # missing required "timestamp" key
    }

    job = ControllerEventIngestJob.new(payload)
    simulate_exhausted_retries(job)

    assert_difference -> { Fault.count }, 1 do
      assert_nothing_raised { job.perform_now }
    end

    fault = Fault.order(:id).last
    assert_nil fault.zone
    assert_equal "CONTROLLER_EVENT_INGEST_FAILED", fault.fault_code
  end

  test "retries instead of raising or creating a fault before attempts are exhausted" do
    payload = { "zone_id" => "zone1", "action" => "water" }

    job = ControllerEventIngestJob.new(payload)

    assert_no_difference -> { Fault.count } do
      assert_enqueued_with(job: ControllerEventIngestJob) do
        assert_nothing_raised { job.perform_now }
      end
    end
  end
end
