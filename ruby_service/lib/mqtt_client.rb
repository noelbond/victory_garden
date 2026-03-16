require "mqtt"

module MqttClient
  module_function

  def publish_command(command)
    publish(setting_value("command_topic", "MQTT_COMMAND_TOPIC", "greenhouse/irrigation/commands"), command)
  end

  def request_reading(zone_id:, command_id:)
    publish(
      "greenhouse/zones/#{zone_id}/command",
      {
        schema_version: "node-command/v1",
        command: "request_reading",
        command_id: command_id
      },
      retain: true
    )
  end

  def publish_config(payload)
    publish(setting_value("config_topic", "MQTT_CONFIG_TOPIC", "greenhouse/config/current"), payload)
  end

  def publish(topic, payload, retain: false)
    MQTT::Client.connect(mqtt_options) do |c|
      c.publish(topic, payload.to_json, retain)
    end
  end

  def mqtt_options
    {
      host: setting_value("mqtt_host", "MQTT_HOST", "localhost"),
      port: Integer(setting_value("mqtt_port", "MQTT_PORT", "1883"))
    }
  end

  def setting_value(attr, env_key, fallback)
    setting = ConnectionSetting.first
    value = setting&.public_send(attr)
    value = value.to_s if value.is_a?(Integer)
    value.presence || ENV.fetch(env_key, fallback)
  end
end
