require "test_helper"

class SensorIngestJobTest < ActiveSupport::TestCase
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

  # retry_on's attempt counter lives in `exception_executions` (keyed by the
  # exception class list), not the plain `executions` attribute -- this
  # simulates the job being one rescue away from exhausting `attempts: 3`.
  def simulate_exhausted_retries(job)
    job.exception_executions = { [StandardError].to_s => 2 }
  end

  test "ingests a valid payload for an assigned node" do
    zone = create(:zone, zone_id: "zone1")
    Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    payload = {
      "node_id" => "sensor-zone1",
      "zone_id" => "zone1",
      "timestamp" => Time.current.utc.iso8601,
      "moisture_raw" => 500
    }

    assert_difference -> { SensorReading.count }, 1 do
      SensorIngestJob.perform_now(payload)
    end
  end

  test "creates a fault with the resolved zone after exhausting retries on a malformed payload" do
    zone = create(:zone, zone_id: "zone1")
    Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    payload = {
      "node_id" => "sensor-zone1",
      "zone_id" => "zone1",
      # missing required "timestamp" key
      "moisture_raw" => 500
    }

    job = SensorIngestJob.new(payload)
    simulate_exhausted_retries(job)

    assert_difference -> { Fault.count }, 1 do
      assert_nothing_raised { job.perform_now }
    end

    fault = Fault.order(:id).last
    assert_equal zone, fault.zone
    assert_equal "sensor-zone1", fault.node_id
    assert_equal "SENSOR_INGEST_FAILED", fault.fault_code
    assert_includes fault.detail, "3 attempts"
    assert_includes fault.detail, "missing required key"
  end

  test "creates a zoneless fault when the payload references an unknown zone_id" do
    payload = {
      "node_id" => "orphan-node",
      "zone_id" => "no-such-zone",
      "moisture_raw" => 500
      # missing required "timestamp" key
    }

    job = SensorIngestJob.new(payload)
    simulate_exhausted_retries(job)

    assert_difference -> { Fault.count }, 1 do
      assert_nothing_raised { job.perform_now }
    end

    fault = Fault.order(:id).last
    assert_nil fault.zone
    assert_equal "orphan-node", fault.node_id
    assert_equal "SENSOR_INGEST_FAILED", fault.fault_code
  end

  test "retries instead of raising or creating a fault before attempts are exhausted" do
    payload = {
      "node_id" => "sensor-zone1",
      "zone_id" => "zone1",
      "moisture_raw" => 500
    }

    job = SensorIngestJob.new(payload)

    assert_no_difference -> { Fault.count } do
      assert_enqueued_with(job: SensorIngestJob) do
        assert_nothing_raised { job.perform_now }
      end
    end
  end
end
