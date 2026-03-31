require "test_helper"

class FullLoopTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def load_fixture(name)
    JSON.parse(File.read(Rails.root.join("..", "contracts", "examples", name)))
  end

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    @crop = create(:crop_profile, crop_id: "tomato-full-loop")
    @zone = create(:zone, zone_id: "zone1", name: "Zone 1", crop_profile: @crop)
    @node = Node.create!(
      node_id: "pico-full-loop",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "completed actuator run schedules reread for an existing watering event" do
    event = nil
    freeze_time do
      event = WateringEvent.create!(
        zone: @zone,
        command: "start_watering",
        runtime_seconds: 45,
        reason: "manual_trigger",
        issued_at: Time.current,
        idempotency_key: "zone1-manual-run-001",
        status: "queued"
      )

      completion_payload = {
        "zone_id" => @zone.zone_id,
        "state" => "COMPLETED",
        "timestamp" => "2026-03-31T18:01:00Z",
        "idempotency_key" => event.idempotency_key,
        "actual_runtime_seconds" => event.runtime_seconds
      }

      assert_enqueued_with(
        job: RequestReadingJob,
        args: [{ zone_id: "zone1", command_id: "#{event.idempotency_key}-reread" }],
        at: 5.minutes.from_now
      ) do
        ActuatorStatusIngestor.new(completion_payload).call
      end
    end

    assert_equal "completed", event.reload.status
  end

  test "low reread shortly after watering does not create a new automatic watering event in rails" do
    reread_time = Time.utc(2026, 3, 31, 18, 6, 0)
    low_reread_payload = load_fixture("node-state-v1.json").merge(
      "node_id" => @node.node_id,
      "zone_id" => @zone.zone_id,
      "timestamp" => reread_time.iso8601,
      "publish_reason" => "request_reading",
      "moisture_percent" => 17.0,
      "moisture_raw" => 354
    )

    travel_to(reread_time) do
      assert_no_enqueued_jobs only: CommandPublishJob do
        SensorIngestor.new(low_reread_payload).call
      end
    end

    assert_equal 0, WateringEvent.count
  end
end
