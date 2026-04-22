require "test_helper"

class MqttConsumerTest < ActiveSupport::TestCase
  test "parse_json ignores empty retained clears" do
    consumer = MqttConsumer.new

    assert_nil consumer.send(:parse_json, "")
    assert_nil consumer.send(:parse_json, nil)
  end

  test "connect_and_subscribe logs MQTT protocol errors without raising" do
    consumer = MqttConsumer.new
    logs = []
    original_connect = MQTT::Client.method(:connect)

    MQTT::Client.define_singleton_method(:connect, ->(_options) { raise MQTT::ProtocolException, "boom" })
    begin
      consumer.define_singleton_method(:log) { |msg, level: :info| logs << [msg, level] }
      consumer.send(:connect_and_subscribe)
    ensure
      consumer.singleton_class.remove_method(:log)
      MQTT::Client.define_singleton_method(:connect, &original_connect)
    end

    assert_equal [["MQTT error: MQTT::ProtocolException boom", :error]], logs
  end

  test "replayed sensor messages within the dedupe window are only enqueued once" do
    now = 100.0
    consumer = MqttConsumer.new(dedupe_window_seconds: 60, monotonic_clock: -> { now })
    payload = { zone_id: "zone1", node_id: "node-1", moisture_raw: 321, timestamp: "2026-04-06T18:00:00Z" }.to_json
    enqueued = []
    original = SensorIngestJob.method(:perform_later)

    SensorIngestJob.define_singleton_method(:perform_later, ->(data) { enqueued << data })
    begin
      consumer.send(:handle_message, "greenhouse/zones/zone1/state", payload)
      consumer.send(:handle_message, "greenhouse/zones/zone1/state", payload)
      now += 61
      consumer.send(:handle_message, "greenhouse/zones/zone1/state", payload)
    ensure
      SensorIngestJob.define_singleton_method(:perform_later, &original)
    end

    assert_equal 2, enqueued.length
  end

  test "node-scoped sensor state topic is routed to sensor ingest" do
    consumer = MqttConsumer.new
    payload = { zone_id: "zone1", node_id: "node-1", moisture_raw: 321, timestamp: "2026-04-06T18:00:00Z" }.to_json
    enqueued = []
    original = SensorIngestJob.method(:perform_later)

    SensorIngestJob.define_singleton_method(:perform_later, ->(data) { enqueued << data })
    begin
      consumer.send(:handle_message, "greenhouse/zones/zone1/nodes/node-1/state", payload)
    ensure
      SensorIngestJob.define_singleton_method(:perform_later, &original)
    end

    assert_equal 1, enqueued.length
    assert_equal "node-1", enqueued.first["node_id"]
  end

  test "controller events are deduped by payload within the dedupe window" do
    now = 100.0
    consumer = MqttConsumer.new(dedupe_window_seconds: 60, monotonic_clock: -> { now })
    payload = {
      zone_id: "zone1",
      action: "water",
      runtime_seconds: 45,
      timestamp: "2026-04-06T18:00:00Z",
      idempotency_key: "zone1-20260406T180000Z-abc12345"
    }.to_json
    enqueued = []
    original = ControllerEventIngestJob.method(:perform_later)

    ControllerEventIngestJob.define_singleton_method(:perform_later, ->(data) { enqueued << data })
    begin
      consumer.send(:handle_message, "greenhouse/zones/zone1/controller/event", payload)
      consumer.send(:handle_message, "greenhouse/zones/zone1/controller/event", payload)
    ensure
      ControllerEventIngestJob.define_singleton_method(:perform_later, &original)
    end

    assert_equal 1, enqueued.length
  end
end
