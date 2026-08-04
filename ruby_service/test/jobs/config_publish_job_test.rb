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

  def with_publish_config_stub(callable, &block)
    stub_singleton_method(MqttClient, :publish_config, callable, &block)
  end

  def with_publish_actuator_config_stub(callable, &block)
    stub_singleton_method(MqttClient, :publish_actuator_config, callable, &block)
  end

  def simulate_exhausted_retries(job)
    job.exception_executions = { [StandardError, MQTT::Exception].to_s => 2 }
  end

  test "creates a zoneless fault after exhausting retries on a publish failure" do
    job = ConfigPublishJob.new
    simulate_exhausted_retries(job)

    assert_difference -> { Fault.count }, 1 do
      with_publish_config_stub(->(_payload) { raise MQTT::NotConnectedException }) do
        assert_nothing_raised { job.perform_now }
      end
    end

    fault = Fault.order(:id).last
    assert_nil fault.zone
    assert_equal "CONFIG_PUBLISH_FAILED", fault.fault_code
    assert_includes fault.detail, "3 attempts"
  end

  test "retries instead of raising or creating a fault before attempts are exhausted" do
    job = ConfigPublishJob.new

    assert_no_difference -> { Fault.count } do
      with_publish_config_stub(->(_payload) { raise MQTT::NotConnectedException }) do
        assert_enqueued_with(job: ConfigPublishJob) do
          assert_nothing_raised { job.perform_now }
        end
      end
    end
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

  test "enqueues one node config publish per physical sensor device" do
    zone = create(:zone, zone_id: "zone1")
    channels = 4.times.map do |channel|
      Node.create!(
        node_id: "sensor-zone1-ch#{channel}",
        device_id: "sensor-zone1",
        zone: zone,
        last_seen_at: Time.current
      )
    end

    with_publish_config_stub(->(_payload) {}) do
      with_publish_actuator_config_stub(->(_payload) {}) do
        assert_enqueued_jobs 1, only: PublishNodeConfigJob do
          ConfigPublishJob.perform_now
        end
      end
    end

    assert_enqueued_with(job: PublishNodeConfigJob, args: [channels.first.id])
  end

  test "publishes node watering targets for controller and actuator config" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    zone_crop = create(:crop_profile, crop_id: "tomato-zone")
    plant_crop = create(:crop_profile, crop_id: "squash-plant")
    zone = create(:zone, zone_id: "zone1", crop_profile: zone_crop, active: true, irrigation_line: nil)
    node = Node.create!(
      node_id: "sensor-zone1-ch0",
      device_id: "sensor-zone1",
      zone: zone,
      crop_profile: plant_crop,
      irrigation_line: 2,
      last_seen_at: Time.current
    )
    published_payloads = []
    published_actuator_payloads = []

    with_publish_config_stub(->(payload) { published_payloads << payload }) do
      with_publish_actuator_config_stub(->(payload) { published_actuator_payloads << payload }) do
        ConfigPublishJob.perform_now
      end
    end

    payload = published_payloads.fetch(0)
    actuator_payload = published_actuator_payloads.fetch(0)
    assert_equal "node", payload[:watering_mode]
    assert_equal(
      [{ node_id: node.node_id, zone_id: zone.zone_id, crop_id: plant_crop.crop_id, active: true, allowed_hours: zone.allowed_hours, irrigation_line: 2 }],
      payload[:nodes]
    )
    assert_equal(
      [{ node_id: node.node_id, zone_id: zone.zone_id, irrigation_line: 2, active: true }],
      actuator_payload[:nodes]
    )
  end
end
