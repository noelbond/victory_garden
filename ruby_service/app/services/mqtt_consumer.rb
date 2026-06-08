require "digest"
require "fileutils"
require "json"
require "mqtt"
require "tempfile"

class MqttConsumer
  CANONICAL_NODE_READINGS_TOPIC = "greenhouse/zones/+/nodes/+/state"
  STATUS_PATH = Rails.root.join("tmp/mqtt_consumer_status.json")
  DEFAULT_RECONNECT_BASE_SECONDS = 1.0
  DEFAULT_RECONNECT_MAX_SECONDS = 30.0
  DEGRADED_RETRY_THRESHOLD = 3

  def initialize(
    dedupe_window_seconds: 120,
    monotonic_clock: nil,
    sleeper: nil,
    status_path: STATUS_PATH,
    reconnect_base_seconds: DEFAULT_RECONNECT_BASE_SECONDS,
    reconnect_max_seconds: DEFAULT_RECONNECT_MAX_SECONDS,
    wall_clock: nil
  )
    @settings = ConnectionSetting.first
    @host = setting_value("mqtt_host", "MQTT_HOST", "localhost")
    @port = Integer(setting_value("mqtt_port", "MQTT_PORT", "1883"))
    @username = setting_value("mqtt_username", "MQTT_USERNAME", nil)
    @password = setting_value("mqtt_password", "MQTT_PASSWORD", nil)
    @node_readings_topic = CANONICAL_NODE_READINGS_TOPIC
    configured_readings_topic = setting_value("readings_topic", "MQTT_READINGS_TOPIC", @node_readings_topic)
    @readings_topic = normalize_readings_topic(configured_readings_topic)
    @actuators_topic = normalized_actuators_topic
    @controller_events_topic = "greenhouse/zones/+/controller/event"
    @node_config_ack_topic = "greenhouse/nodes/+/config_ack"
    @dedupe_window_seconds = dedupe_window_seconds
    @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    @sleeper = sleeper || ->(seconds) { sleep seconds }
    @status_path = status_path
    @reconnect_base_seconds = reconnect_base_seconds
    @reconnect_max_seconds = reconnect_max_seconds
    @wall_clock = wall_clock || -> { Time.current }
    @recent_message_fingerprints = {}
    write_status(status: "starting", connected: false, retry_count: 0, last_error: nil, next_retry_at: nil)
  end

  def run
    retry_count = 0
    loop do
      retry_count = connect_cycle(retry_count)
    end
  end

  private

  def connect_cycle(retry_count)
    connect_and_subscribe
    retry_later("connection_closed", retry_count + 1, level: :warn)
  rescue MQTT::Exception, StandardError => e
    retry_later("#{e.class} #{e.message}", retry_count + 1, level: :error)
  end

  def connect_and_subscribe
    MQTT::Client.connect(mqtt_options) do |client|
      topics = [@readings_topic, @actuators_topic, @controller_events_topic, @node_config_ack_topic].compact.uniq
      client.subscribe(*topics)
      log "Subscribed to #{topics.join(', ')}"
      mark_connected(topics)
      client.get do |topic, message|
        handle_message(topic, message)
      end
    end
  end

  def handle_message(topic, message)
    payload = parse_json(message)
    return unless payload
    return if replayed_message?(topic, message)

    if sensor_topic?(topic)
      data = payload["sensor_reading"] || payload
      SensorIngestJob.perform_later(data)
    elsif topic_matches?(@actuators_topic, topic)
      data = payload["actuator_status"] || payload
      ActuatorStatusIngestJob.perform_later(data)
    elsif topic_matches?(@controller_events_topic, topic)
      data = payload["controller_event"] || payload
      ControllerEventIngestJob.perform_later(data)
    elsif topic_matches?(@node_config_ack_topic, topic)
      data = payload["node_config_ack"] || payload
      NodeConfigAckIngestJob.perform_later(data)
    else
      log "Unknown topic: #{topic}", level: :warn
    end
  end

  def parse_json(message)
    return nil if message.blank?

    JSON.parse(message)
  rescue JSON::ParserError => e
    log "Invalid JSON: #{e.message}", level: :warn
    nil
  end

  def log(msg, level: :info)
    Rails.logger.public_send(level, "[mqtt_consumer] #{msg}")
  end

  def mark_connected(topics)
    write_status(
      status: "connected",
      connected: true,
      retry_count: 0,
      last_error: nil,
      next_retry_at: nil,
      topics: topics,
      last_connected_at: @wall_clock.call.iso8601
    )
  end

  def retry_later(error_message, retry_count, level:)
    delay = retry_delay_seconds(retry_count)
    status = retry_count >= DEGRADED_RETRY_THRESHOLD ? "degraded" : "retrying"
    next_retry_at = @wall_clock.call + delay
    log(
      "MQTT error: #{error_message} (attempt #{retry_count}, retrying in #{delay.round(2)}s)",
      level: level
    )
    write_status(
      status: status,
      connected: false,
      retry_count: retry_count,
      last_error: error_message,
      next_retry_at: next_retry_at.iso8601
    )
    @sleeper.call(delay)
    retry_count
  end

  def retry_delay_seconds(retry_count)
    delay = @reconnect_base_seconds * (2**(retry_count - 1))
    [delay, @reconnect_max_seconds].min
  end

  def write_status(status:, connected:, retry_count:, last_error:, next_retry_at:, topics: nil, last_connected_at: nil)
    payload = read_status
    payload["component"] = "mqtt_consumer"
    payload["mqtt_host"] = @host
    payload["mqtt_port"] = @port
    payload["status"] = status
    payload["connected"] = connected
    payload["retry_count"] = retry_count
    payload["last_error"] = last_error
    payload["next_retry_at"] = next_retry_at
    payload["updated_at"] = @wall_clock.call.iso8601
    payload["topics"] = topics if topics
    payload["last_connected_at"] = last_connected_at if last_connected_at
    atomic_write_status(payload)
  end

  def read_status
    return {} unless @status_path.exist?

    JSON.parse(File.read(@status_path))
  rescue JSON::ParserError
    {}
  end

  def atomic_write_status(payload)
    FileUtils.mkdir_p(@status_path.dirname)
    Tempfile.create([@status_path.basename.to_s, ".tmp"], @status_path.dirname.to_s) do |file|
      file.write(JSON.pretty_generate(payload))
      file.flush
      file.fsync
      File.rename(file.path, @status_path)
    end
  end

  def topic_matches?(pattern, topic)
    pattern_parts = pattern.split("/")
    topic_parts = topic.split("/")
    return false unless pattern_parts.length == topic_parts.length

    pattern_parts.zip(topic_parts).all? do |expected, actual|
      expected == "+" || expected == actual
    end
  end

  def normalized_actuators_topic
    topic = setting_value("actuators_topic", "MQTT_ACTUATORS_TOPIC", "greenhouse/zones/+/actuator/status")
    topic == "greenhouse/zones/+/actuator_status" ? "greenhouse/zones/+/actuator/status" : topic
  end

  def setting_value(attr, env_key, fallback)
    value = @settings&.public_send(attr)
    value = value.to_s if value.is_a?(Integer)
    value.presence || ENV.fetch(env_key, fallback)
  end

  def normalize_readings_topic(topic)
    topic == "greenhouse/zones/+/state" ? CANONICAL_NODE_READINGS_TOPIC : topic
  end

  def mqtt_options
    options = { host: @host, port: @port }
    options[:username] = @username if @username.present?
    options[:password] = @password if @password.present?
    options
  end

  def replayed_message?(topic, message)
    return false unless dedupe_topic?(topic)

    now = @monotonic_clock.call
    prune_recent_message_fingerprints(now)
    fingerprint = Digest::SHA256.hexdigest("#{topic}\0#{message}")
    expires_at = @recent_message_fingerprints[fingerprint]
    return true if expires_at.present? && expires_at > now

    @recent_message_fingerprints[fingerprint] = now + @dedupe_window_seconds
    false
  end

  def dedupe_topic?(topic)
    sensor_topic?(topic) ||
      topic_matches?(@actuators_topic, topic) ||
      topic_matches?(@controller_events_topic, topic) ||
      topic_matches?(@node_config_ack_topic, topic)
  end

  def sensor_topic?(topic)
    topic_matches?(@readings_topic, topic)
  end

  def prune_recent_message_fingerprints(now)
    @recent_message_fingerprints.delete_if { |_fingerprint, expires_at| expires_at <= now }
  end
end
