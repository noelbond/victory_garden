require "test_helper"

class RequestReadingJobTest < ActiveSupport::TestCase
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

  def with_request_reading_stub(callable, &block)
    stub_singleton_method(MqttClient, :request_reading, callable, &block)
  end

  test "publishes targeted retained request" do
    calls = []

    with_request_reading_stub(->(**payload) { calls << [:request_reading, payload] }) do
      RequestReadingJob.perform_now(zone_id: "zone1", command_id: "cmd-1", node_id: "node-a")
    end

    assert_equal [[:request_reading, { zone_id: "zone1", command_id: "cmd-1", node_id: "node-a" }]], calls
  end

  test "marks a tracked command sent" do
    zone = create(:zone, zone_id: "zone1")
    command = NodeCommand.create!(
      zone: zone,
      node_id: "node-a",
      command: "request_reading",
      command_id: "cmd-tracked-1",
      status: "queued",
      issued_at: Time.current
    )

    with_request_reading_stub(->(**_payload) {}) do
      RequestReadingJob.perform_now(zone_id: "zone1", command_id: "cmd-tracked-1", node_id: "node-a")
    end

    assert_equal "command_sent", command.reload.status
  end

  test "is a no-op for tracking when no NodeCommand exists for the command_id" do
    with_request_reading_stub(->(**_payload) {}) do
      assert_nothing_raised do
        RequestReadingJob.perform_now(zone_id: "zone1", command_id: "cmd-untracked", node_id: "node-a")
      end
    end
  end

  test "does not mark the command sent if the publish fails -- left available for the independent timeout watchdog to catch" do
    zone = create(:zone, zone_id: "zone1")
    command = NodeCommand.create!(
      zone: zone,
      node_id: "node-a",
      command: "request_reading",
      command_id: "cmd-tracked-2",
      status: "queued",
      issued_at: Time.current
    )

    # MQTT::Exception (not a StandardError subclass) is now caught by
    # retry_on explicitly -- perform_now doesn't raise, it retries.
    with_request_reading_stub(->(**_payload) { raise MQTT::NotConnectedException }) do
      assert_enqueued_with(job: RequestReadingJob) do
        assert_nothing_raised do
          RequestReadingJob.perform_now(zone_id: "zone1", command_id: "cmd-tracked-2", node_id: "node-a")
        end
      end
    end

    assert_equal "queued", command.reload.status
  end
end
