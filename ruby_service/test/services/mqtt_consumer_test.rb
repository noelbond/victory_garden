require "test_helper"
require "tmpdir"

class MqttConsumerTest < ActiveSupport::TestCase
  setup do
    @status_dir = Dir.mktmpdir("mqtt-consumer-test")
    @status_path = Pathname.new(File.join(@status_dir, "mqtt_consumer_status.json"))
  end

  teardown do
    FileUtils.remove_entry(@status_dir) if @status_dir && Dir.exist?(@status_dir)
  end

  test "parse_json ignores empty retained clears" do
    consumer = MqttConsumer.new(status_path: @status_path)

    assert_nil consumer.send(:parse_json, "")
    assert_nil consumer.send(:parse_json, nil)
  end

  test "connect_cycle logs protocol errors writes status and sleeps with backoff" do
    slept = []
    consumer = MqttConsumer.new(
      status_path: @status_path,
      sleeper: ->(seconds) { slept << seconds },
      reconnect_base_seconds: 2,
      reconnect_max_seconds: 30
    )
    logs = []
    consumer.define_singleton_method(:log) { |msg, level: :info| logs << [msg, level] }
    consumer.define_singleton_method(:connect_and_subscribe) { raise MQTT::ProtocolException, "boom" }

    retry_count = consumer.send(:connect_cycle, 0)
    status = JSON.parse(File.read(@status_path))

    assert_equal 1, retry_count
    assert_equal [2], slept
    assert_equal "retrying", status["status"]
    assert_equal false, status["connected"]
    assert_equal 1, status["retry_count"]
    assert_equal "MQTT::ProtocolException boom", status["last_error"]
    assert_equal [["MQTT error: MQTT::ProtocolException boom (attempt 1, retrying in 2s)", :error]], logs
  end

  test "replayed sensor messages within the dedupe window are only enqueued once" do
    now = 100.0
    consumer = MqttConsumer.new(dedupe_window_seconds: 60, monotonic_clock: -> { now }, status_path: @status_path)
    payload = { zone_id: "zone1", node_id: "node-1", moisture_raw: 321, timestamp: "2026-04-06T18:00:00Z" }.to_json
    enqueued = []
    original = SensorIngestJob.method(:perform_later)

    SensorIngestJob.define_singleton_method(:perform_later, ->(data) { enqueued << data })
    begin
      consumer.send(:handle_message, "greenhouse/zones/zone1/nodes/node-1/state", payload)
      consumer.send(:handle_message, "greenhouse/zones/zone1/nodes/node-1/state", payload)
      now += 61
      consumer.send(:handle_message, "greenhouse/zones/zone1/nodes/node-1/state", payload)
    ensure
      SensorIngestJob.define_singleton_method(:perform_later, &original)
    end

    assert_equal 2, enqueued.length
  end

  test "legacy configured readings topic is normalized to canonical node topic" do
    consumer = MqttConsumer.new(status_path: @status_path)
    assert_equal "greenhouse/zones/+/nodes/+/state", consumer.instance_variable_get(:@readings_topic)
  end

  test "node-scoped sensor state topic is routed to sensor ingest" do
    consumer = MqttConsumer.new(status_path: @status_path)
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

  test "actuator status topic is routed to actuator status ingest job" do
    consumer = MqttConsumer.new(status_path: @status_path)
    payload = { zone_id: "zone1", state: "COMPLETED", timestamp: "2026-04-06T18:00:00Z" }.to_json
    enqueued = []
    original = ActuatorStatusIngestJob.method(:perform_later)

    ActuatorStatusIngestJob.define_singleton_method(:perform_later, ->(data) { enqueued << data })
    begin
      consumer.send(:handle_message, "greenhouse/zones/zone1/actuator/status", payload)
    ensure
      ActuatorStatusIngestJob.define_singleton_method(:perform_later, &original)
    end

    assert_equal 1, enqueued.length
    assert_equal "COMPLETED", enqueued.first["state"]
  end

  test "node config ack topic is routed to node config ack ingest job" do
    consumer = MqttConsumer.new(status_path: @status_path)
    payload = { node_id: "pico-w-zone1", status: "applied", config_version: "abc123" }.to_json
    enqueued = []
    original = NodeConfigAckIngestJob.method(:perform_later)

    NodeConfigAckIngestJob.define_singleton_method(:perform_later, ->(data) { enqueued << data })
    begin
      consumer.send(:handle_message, "greenhouse/nodes/pico-w-zone1/config_ack", payload)
    ensure
      NodeConfigAckIngestJob.define_singleton_method(:perform_later, &original)
    end

    assert_equal 1, enqueued.length
    assert_equal "pico-w-zone1", enqueued.first["node_id"]
  end

  test "controller events are deduped by payload within the dedupe window" do
    now = 100.0
    consumer = MqttConsumer.new(dedupe_window_seconds: 60, monotonic_clock: -> { now }, status_path: @status_path)
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

  test "connect_and_subscribe writes connected status after subscribing" do
    fake_client = Object.new
    subscribed_topics = nil
    fake_client.define_singleton_method(:subscribe) { |*topics| subscribed_topics = topics }
    fake_client.define_singleton_method(:get) { |_block = nil| }
    consumer = MqttConsumer.new(status_path: @status_path, wall_clock: -> { Time.zone.parse("2026-05-26T15:00:00Z") })
    original_connect = MQTT::Client.method(:connect)

    MQTT::Client.define_singleton_method(:connect, ->(_options, &block) { block.call(fake_client) })
    begin
      consumer.send(:connect_and_subscribe)
    ensure
      MQTT::Client.define_singleton_method(:connect, &original_connect)
    end

    status = JSON.parse(File.read(@status_path))
    assert_equal "connected", status["status"]
    assert_equal true, status["connected"]
    assert_equal 0, status["retry_count"]
    assert_equal subscribed_topics, status["topics"]
  end

  test "connect_cycle escalates to degraded after repeated retries" do
    slept = []
    consumer = MqttConsumer.new(
      status_path: @status_path,
      sleeper: ->(seconds) { slept << seconds },
      reconnect_base_seconds: 1,
      reconnect_max_seconds: 30
    )
    consumer.define_singleton_method(:connect_and_subscribe) { raise MQTT::ProtocolException, "boom" }

    retry_count = 0
    3.times { retry_count = consumer.send(:connect_cycle, retry_count) }

    status = JSON.parse(File.read(@status_path))
    assert_equal 3, retry_count
    assert_equal [1, 2, 4], slept
    assert_equal "degraded", status["status"]
    assert_equal 3, status["retry_count"]
  end
end
