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

  def with_lora_request_reading_stub(callable, &block)
    stub_singleton_method(MqttClient, :request_lora_reading, callable, &block)
  end

  test "publishes targeted retained request" do
    calls = []

    with_request_reading_stub(->(**payload) { calls << [:request_reading, payload] }) do
      RequestReadingJob.perform_now(zone_id: "zone1", command_id: "cmd-1", node_id: "node-a")
    end

    assert_equal [[:request_reading, { zone_id: "zone1", command_id: "cmd-1", node_id: "node-a" }]], calls
  end

  test "publishes lora request for lora transport node" do
    zone = create(:zone, zone_id: "zone1")
    Node.create!(
      node_id: "sensor-zone1-ch0",
      zone: zone,
      last_seen_at: Time.current,
      communication_transport: "lora"
    )
    calls = []

    with_request_reading_stub(->(**payload) { calls << [:wifi, payload] }) do
      with_lora_request_reading_stub(->(**payload) { calls << [:lora, payload] }) do
        RequestReadingJob.perform_now(zone_id: "zone1", command_id: "cmd-lora-1", node_id: "sensor-zone1-ch0")
      end
    end

    assert_equal [[:lora, { node_id: "sensor-zone1-ch0", command_id: "cmd-lora-1" }]], calls
  end

  test "auto transport remains on wifi path until auto routing is defined" do
    zone = create(:zone, zone_id: "zone1")
    Node.create!(
      node_id: "sensor-zone1-auto",
      zone: zone,
      last_seen_at: Time.current,
      communication_transport: "auto"
    )
    calls = []

    with_request_reading_stub(->(**payload) { calls << [:wifi, payload] }) do
      with_lora_request_reading_stub(->(**payload) { calls << [:lora, payload] }) do
        RequestReadingJob.perform_now(zone_id: "zone1", command_id: "cmd-auto-1", node_id: "sensor-zone1-auto")
      end
    end

    assert_equal [[:wifi, { zone_id: "zone1", command_id: "cmd-auto-1", node_id: "sensor-zone1-auto" }]], calls
  end

  test "missing node remains on wifi path" do
    calls = []

    with_request_reading_stub(->(**payload) { calls << [:wifi, payload] }) do
      with_lora_request_reading_stub(->(**payload) { calls << [:lora, payload] }) do
        RequestReadingJob.perform_now(zone_id: "zone1", command_id: "cmd-missing-node", node_id: "unknown-node")
      end
    end

    assert_equal [[:wifi, { zone_id: "zone1", command_id: "cmd-missing-node", node_id: "unknown-node" }]], calls
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
