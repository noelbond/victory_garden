require "test_helper"

class ConfigPublishJobTest < ActiveSupport::TestCase
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

  def with_publish_config_stub(callable)
    original = MqttClient.method(:publish_config)
    MqttClient.define_singleton_method(:publish_config, &callable)
    yield
  ensure
    MqttClient.define_singleton_method(:publish_config, &original)
  end

  test "publishes crops referenced by active zones even when the crop is inactive" do
    crop = create(:crop_profile, crop_id: "tomato", active: false)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop, active: true)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    published_payloads = []

    with_publish_config_stub(->(payload) { published_payloads << payload }) do
      assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
        ConfigPublishJob.perform_now
      end
    end

    payload = published_payloads.fetch(0)
    assert_equal ["tomato"], payload[:crops].map { |entry| entry[:crop_id] }
    assert_equal ["zone1"], payload[:zones].map { |entry| entry[:zone_id] }
  end
end
