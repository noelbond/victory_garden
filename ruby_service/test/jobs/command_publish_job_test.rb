require "test_helper"

class CommandPublishJobTest < ActiveSupport::TestCase
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

  def with_publish_command_stub(callable)
    original = MqttClient.method(:publish_command)
    MqttClient.define_singleton_method(:publish_command, &callable)
    yield
  ensure
    MqttClient.define_singleton_method(:publish_command, &original)
  end

  test "publishes actuator command and schedules timeout watchdog for start_watering" do
    command = {
      command: "start_watering",
      zone_id: "zone1",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.current,
      idempotency_key: "zone1-cmd-001"
    }

    published = []

    with_publish_command_stub(->(payload) { published << payload }) do
      freeze_time do
        assert_enqueued_with(
          job: ActuatorCommandTimeoutJob,
          args: [{ idempotency_key: "zone1-cmd-001", timeout_seconds: 75 }],
          at: 75.seconds.from_now
        ) do
          CommandPublishJob.perform_now(command)
        end
      end
    end

    assert_equal [command], published
  end

  test "schedules a shorter watchdog for stop_watering" do
    command = {
      command: "stop_watering",
      zone_id: "zone1",
      runtime_seconds: nil,
      reason: "manual_stop",
      issued_at: Time.current,
      idempotency_key: "zone1-cmd-002"
    }

    with_publish_command_stub(->(_payload) {}) do
      freeze_time do
        assert_enqueued_with(
          job: ActuatorCommandTimeoutJob,
          args: [{ idempotency_key: "zone1-cmd-002", timeout_seconds: 30 }],
          at: 30.seconds.from_now
        ) do
          CommandPublishJob.perform_now(command)
        end
      end
    end
  end

  test "skips watchdog when idempotency key is missing" do
    command = {
      command: "start_watering",
      zone_id: "zone1",
      runtime_seconds: 45
    }

    with_publish_command_stub(->(_payload) {}) do
      assert_no_enqueued_jobs only: ActuatorCommandTimeoutJob do
        CommandPublishJob.perform_now(command)
      end
    end
  end
end
