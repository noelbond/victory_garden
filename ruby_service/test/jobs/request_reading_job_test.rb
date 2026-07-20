require "test_helper"

class RequestReadingJobTest < ActiveSupport::TestCase
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
end
