require "test_helper"

class WateringCommandTest < ActiveSupport::TestCase
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

  test "start schedules a timeout watchdog sized to the crop's max pulse runtime" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop)

    result = WateringCommand.start(zone)

    assert_enqueued_with(
      job: ActuatorCommandTimeoutJob,
      args: [{ idempotency_key: result.payload[:idempotency_key], timeout_seconds: 75 }]
    )
  end

  test "stop schedules the shorter default timeout watchdog" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop)

    result = WateringCommand.stop(zone)

    assert_enqueued_with(
      job: ActuatorCommandTimeoutJob,
      args: [{ idempotency_key: result.payload[:idempotency_key], timeout_seconds: 30 }]
    )
  end

  test "timeout watchdog is scheduled even though CommandPublishJob is never performed here" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop)
    node = Node.create!(node_id: "actuator-zone1", zone: zone, last_seen_at: Time.current, crop_profile: crop, irrigation_line: 1)

    # ActiveJob's :test adapter never actually performs enqueued jobs unless
    # asked to -- this demonstrates the watchdog scheduling doesn't depend
    # on CommandPublishJob (or MqttClient) ever running, only on
    # WateringCommand itself, so a broker outage can't silently swallow it.
    result = WateringCommand.start_node(node)

    assert_enqueued_with(job: ActuatorCommandTimeoutJob, args: [{ idempotency_key: result.payload[:idempotency_key], timeout_seconds: 75 }])
    assert_enqueued_with(job: CommandPublishJob, args: [result.payload])
  end
end
