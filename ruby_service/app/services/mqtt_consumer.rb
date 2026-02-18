require "json"
require "mqtt"

class MqttConsumer
  def initialize
    @settings = ConnectionSetting.first
    @host = setting_value("mqtt_host", "MQTT_HOST", "localhost")
    @port = Integer(setting_value("mqtt_port", "MQTT_PORT", "1883"))
    @readings_topic = setting_value("readings_topic", "MQTT_READINGS_TOPIC", "watering/readings")
    @actuators_topic = setting_value("actuators_topic", "MQTT_ACTUATORS_TOPIC", "watering/actuators")
  end

  def run
    loop do
      connect_and_subscribe
      sleep 1
    end
  end

  private

  def connect_and_subscribe
    MQTT::Client.connect(host: @host, port: @port) do |client|
      client.subscribe(@readings_topic, @actuators_topic)
      log "Subscribed to #{@readings_topic} and #{@actuators_topic}"
      client.get do |topic, message|
        handle_message(topic, message)
      end
    end
  rescue StandardError => e
    log "MQTT error: #{e.class} #{e.message}"
  end

  def handle_message(topic, message)
    payload = parse_json(message)
    return unless payload

    case topic
    when @readings_topic
      data = payload["sensor_reading"] || payload
      SensorIngestJob.perform_later(data)
    when @actuators_topic
      data = payload["actuator_status"] || payload
      ActuatorStatusIngestJob.perform_later(data)
    else
      log "Unknown topic: #{topic}"
    end
  end

  def parse_json(message)
    JSON.parse(message)
  rescue JSON::ParserError => e
    log "Invalid JSON: #{e.message}"
    nil
  end

  def log(msg)
    puts "[mqtt_consumer] #{msg}"
  end

  def setting_value(attr, env_key, fallback)
    value = @settings&.public_send(attr)
    value = value.to_s if value.is_a?(Integer)
    value.presence || ENV.fetch(env_key, fallback)
  end
end
