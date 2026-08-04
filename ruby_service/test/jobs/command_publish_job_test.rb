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

  def with_publish_command_stub(callable, &block)
    stub_singleton_method(MqttClient, :publish_command, callable, &block)
  end

  test "publishes the command and marks the matching watering event sent" do
    command = {
      command: "start_watering",
      zone_id: "zone1",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.current,
      idempotency_key: "zone1-cmd-001"
    }
    zone = create(:zone, zone_id: "zone1")
    event = WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.current,
      idempotency_key: "zone1-cmd-001",
      status: "queued"
    )

    published = []

    with_publish_command_stub(->(payload) { published << payload }) do
      CommandPublishJob.perform_now(command)
    end

    assert_equal [command], published
    assert_equal "command_sent", event.reload.status
  end

  test "does not schedule its own timeout watchdog -- that's scheduled independently by WateringCommand" do
    command = {
      command: "start_watering",
      zone_id: "zone1",
      runtime_seconds: 45,
      idempotency_key: "zone1-cmd-002"
    }

    with_publish_command_stub(->(_payload) {}) do
      assert_no_enqueued_jobs only: ActuatorCommandTimeoutJob do
        CommandPublishJob.perform_now(command)
      end
    end
  end

  test "does not mark the event sent if the publish fails -- left available for the independent timeout watchdog to catch" do
    zone = create(:zone, zone_id: "zone1")
    event = WateringEvent.create!(
      zone: zone,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.current,
      idempotency_key: "zone1-cmd-003",
      status: "queued"
    )
    command = {
      command: "start_watering",
      zone_id: "zone1",
      runtime_seconds: 45,
      idempotency_key: "zone1-cmd-003"
    }

    # MQTT::Exception (not a StandardError subclass) is now caught by
    # retry_on explicitly -- perform_now doesn't raise, it retries.
    with_publish_command_stub(->(_payload) { raise MQTT::NotConnectedException }) do
      assert_enqueued_with(job: CommandPublishJob) do
        assert_nothing_raised do
          CommandPublishJob.perform_now(command)
        end
      end
    end

    assert_equal "queued", event.reload.status
  end
end
