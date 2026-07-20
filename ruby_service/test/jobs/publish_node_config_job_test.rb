require "test_helper"

class PublishNodeConfigJobTest < ActiveSupport::TestCase
  def with_publish_node_config_stub(callable, &block)
    stub_singleton_method(MqttClient, :publish_node_config, callable, &block)
  end

  test "publishes assigned node config and marks node pending" do
    zone = create(
      :zone,
      zone_id: "zone1",
      allowed_hours: { "start_hour" => 6, "end_hour" => 20 },
      publish_interval_ms: 300_000
    )
    node = Node.create!(
      node_id: "pico-zone1",
      zone: zone,
      last_seen_at: Time.current,
      moisture_raw_dry: 552,
      moisture_raw_wet: 943
    )
    published = []

    freeze_time do
      with_publish_node_config_stub(->(node_id:, payload:) { published << [node_id, payload] }) do
        PublishNodeConfigJob.perform_now(node.id)
      end
    end

    node.reload
    topic_node_id, payload = published.fetch(0)
    assert_equal node.node_id, topic_node_id
    assert_equal true, payload[:assigned]
    assert_equal Time.now.getlocal.utc_offset / 3600, payload[:utc_offset_hours]
    assert_equal zone.zone_id, payload.dig(:zone, :zone_id)
    assert_equal zone.allowed_hours, payload.dig(:zone, :allowed_hours)
    assert_equal zone.publish_interval_ms, payload.dig(:zone, :publish_interval_ms)
    assert_equal zone.crop_profile.crop_id, payload.dig(:crop, :crop_id)
    assert_equal 552, payload.dig(:sensor, :moisture_raw_dry)
    assert_equal 943, payload.dig(:sensor, :moisture_raw_wet)
    assert_equal "pending", node.config_status
    assert_equal payload[:config_version], node.config_version
    assert_equal payload.deep_stringify_keys, node.desired_config
    assert_in_delta Time.current.to_f, node.config_published_at.to_f, 1.0
    assert_nil node.config_error
  end

  test "publishes unassigned node config and marks node unassigned" do
    node = Node.create!(node_id: "pico-unassigned", last_seen_at: Time.current)
    published = []

    with_publish_node_config_stub(->(node_id:, payload:) { published << [node_id, payload] }) do
      PublishNodeConfigJob.perform_now(node.id)
    end

    node.reload
    _topic_node_id, payload = published.fetch(0)
    assert_equal false, payload[:assigned]
    assert_equal Time.now.getlocal.utc_offset / 3600, payload[:utc_offset_hours]
    assert_nil payload[:zone]
    assert_nil payload[:crop]
    assert_equal "unassigned", node.config_status
  end

  test "publishes one device config with every channel calibration" do
    zone = create(:zone, zone_id: "zone1", publish_interval_ms: 300_000)
    channels = 4.times.map do |channel|
      Node.create!(
        node_id: "sensor-zone1-ch#{channel}",
        device_id: "sensor-zone1",
        zone: zone,
        last_seen_at: Time.current,
        moisture_raw_dry: 10_000 + channel,
        moisture_raw_wet: 20_000 + channel
      )
    end
    published = []

    with_publish_node_config_stub(->(node_id:, payload:) { published << [node_id, payload] }) do
      PublishNodeConfigJob.perform_now(channels.fetch(2).id)
    end

    assert_equal 1, published.length
    topic_node_id, payload = published.fetch(0)
    assert_equal "sensor-zone1", topic_node_id
    assert_equal "sensor-zone1", payload[:node_id]
    assert_equal Time.now.getlocal.utc_offset / 3600, payload[:utc_offset_hours]
    assert_equal channels.map(&:node_id), payload[:channels].map { |entry| entry[:node_id] }
    assert_equal [10_000, 10_001, 10_002, 10_003], payload[:channels].map { |entry| entry[:moisture_raw_dry] }
    assert_equal [20_000, 20_001, 20_002, 20_003], payload[:channels].map { |entry| entry[:moisture_raw_wet] }
    assert channels.all? { |channel| channel.reload.config_status == "pending" }
    assert channels.all? { |channel| channel.desired_config == payload.deep_stringify_keys }
  end

  test "marks node config status error when publish fails" do
    node = Node.create!(node_id: "pico-error", last_seen_at: Time.current)

    assert_nothing_raised do
      with_publish_node_config_stub(->(**) { raise StandardError, "broker unavailable" }) do
        PublishNodeConfigJob.perform_now(node.id)
      end
    end

    assert_equal "error", node.reload.config_status
    assert_equal "broker unavailable", node.config_error
  end
end
