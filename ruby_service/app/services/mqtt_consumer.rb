require "digest"
require "json"
require "mqtt"

class MqttConsumer
  def initialize(dedupe_window_seconds: 120, monotonic_clock: nil)
    @settings = ConnectionSetting.first
    @host = setting_value("mqtt_host", "MQTT_HOST", "localhost")
    @port = Integer(setting_value("mqtt_port", "MQTT_PORT", "1883"))
    @username = setting_value("mqtt_username", "MQTT_USERNAME", nil)
    @password = setting_value("mqtt_password", "MQTT_PASSWORD", nil)
    @readings_topic = setting_value("readings_topic", "MQTT_READINGS_TOPIC", "greenhouse/zones/+/state")
    @node_readings_topic = "greenhouse/zones/+/nodes/+/state"
    @actuators_topic = normalized_actuators_topic
    @controller_events_topic = "greenhouse/zones/+/controller/event"
    @node_config_ack_topic = "greenhouse/nodes/+/config_ack"
    @dedupe_window_seconds = dedupe_window_seconds
    @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    @recent_message_fingerprints = {}
  end

  def run
    loop do
      connect_and_subscribe
      sleep 1
    end
  end

  private

  def connect_and_subscribe
    MQTT::Client.connect(mqtt_options) do |client|
      client.subscribe(@readings_topic, @node_readings_topic, @actuators_topic, @controller_events_topic, @node_config_ack_topic)
      log "Subscribed to #{@readings_topic}, #{@node_readings_topic}, #{@actuators_topic}, #{@controller_events_topic}, and #{@node_config_ack_topic}"
      client.get do |topic, message|
        handle_message(topic, message)
      end
    end
  rescue MQTT::Exception, StandardError => e
    log "MQTT error: #{e.class} #{e.message}", level: :error
  end

  def handle_message(topic, message)
    payload = parse_json(message)
    return unless payload
    return if replayed_message?(topic, message)

    if topic_matches?(@readings_topic, topic) || topic_matches?(@node_readings_topic, topic)
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
    topic_matches?(@readings_topic, topic) ||
      topic_matches?(@node_readings_topic, topic) ||
      topic_matches?(@actuators_topic, topic) ||
      topic_matches?(@controller_events_topic, topic) ||
      topic_matches?(@node_config_ack_topic, topic)
  end

  def prune_recent_message_fingerprints(now)
    @recent_message_fingerprints.delete_if { |_fingerprint, expires_at| expires_at <= now }
  end
end
