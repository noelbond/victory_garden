require "test_helper"

class PublishNodeConfigJobTest < ActiveSupport::TestCase
  def with_publish_node_config_stub(callable)
    original = MqttClient.method(:publish_node_config)
    MqttClient.define_singleton_method(:publish_node_config, &callable)
    yield
  ensure
    MqttClient.define_singleton_method(:publish_node_config, &original)
  end

  test "publishes assigned node config and marks node pending" do
    zone = create(:zone, zone_id: "zone1", allowed_hours: { "start_hour" => 6, "end_hour" => 20 })
    node = Node.create!(node_id: "pico-zone1", zone: zone, last_seen_at: Time.current)
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
    assert_equal zone.zone_id, payload.dig(:zone, :zone_id)
    assert_equal zone.allowed_hours, payload.dig(:zone, :allowed_hours)
    assert_equal zone.crop_profile.crop_id, payload.dig(:crop, :crop_id)
    assert_equal "pending", node.config_status
    assert_equal payload[:config_version], node.config_version
    assert_equal payload.deep_stringify_keys, node.desired_config
    assert_equal Time.current.change(usec: 0), node.config_published_at
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
    assert_nil payload[:zone]
    assert_nil payload[:crop]
    assert_equal "unassigned", node.config_status
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
