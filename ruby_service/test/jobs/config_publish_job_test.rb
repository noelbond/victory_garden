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

  def with_publish_actuator_config_stub(callable)
    original = MqttClient.method(:publish_actuator_config)
    MqttClient.define_singleton_method(:publish_actuator_config, &callable)
    yield
  ensure
    MqttClient.define_singleton_method(:publish_actuator_config, &original)
  end

  test "publishes crops referenced by active zones even when the crop is inactive" do
    crop = create(:crop_profile, crop_id: "tomato", active: false)
    zone = create(:zone, zone_id: "zone1", crop_profile: crop, active: true, irrigation_line: 1)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    published_payloads = []
    published_actuator_payloads = []
    ConnectionSetting.create!(irrigation_line_count: 4)

    with_publish_config_stub(->(payload) { published_payloads << payload }) do
      with_publish_actuator_config_stub(->(payload) { published_actuator_payloads << payload }) do
        assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
          ConfigPublishJob.perform_now
        end
      end
    end

    payload = published_payloads.fetch(0)
    actuator_payload = published_actuator_payloads.fetch(0)
    assert_equal ["tomato"], payload[:crops].map { |entry| entry[:crop_id] }
    assert_equal ["zone1"], payload[:zones].map { |entry| entry[:zone_id] }
    assert_equal 1, payload[:zones].first[:irrigation_line]
    assert_equal "actuator-config/v1", actuator_payload[:schema_version]
    assert_equal 4, actuator_payload[:irrigation_line_count]
    assert_equal [{ zone_id: "zone1", irrigation_line: 1, active: true }], actuator_payload[:zones]
  end

  test "publishes actuator topology ordered by irrigation line and keeps assigned inactive zones" do
    crop = create(:crop_profile, crop_id: "tomato")
    zone2 = create(:zone, zone_id: "zone2", crop_profile: crop, active: true, irrigation_line: 2)
    zone1 = create(:zone, zone_id: "zone1", crop_profile: crop, active: false, irrigation_line: 1)
    Node.create!(node_id: "sensor-zone2", zone: zone2, last_seen_at: Time.current)
    ConnectionSetting.create!(irrigation_line_count: 3)
    published_actuator_payloads = []

    with_publish_config_stub(->(_payload) {}) do
      with_publish_actuator_config_stub(->(payload) { published_actuator_payloads << payload }) do
        ConfigPublishJob.perform_now
      end
    end

    actuator_payload = published_actuator_payloads.fetch(0)
    assert_equal 3, actuator_payload[:irrigation_line_count]
    assert_equal(
      [
        { zone_id: "zone1", irrigation_line: 1, active: false },
        { zone_id: "zone2", irrigation_line: 2, active: true }
      ],
      actuator_payload[:zones]
    )
  end
end
