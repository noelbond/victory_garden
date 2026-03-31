require "mqtt"

module MqttClient
  module_function

  def publish_command(command)
    zone_id = command[:zone_id] || command["zone_id"]
    raise ArgumentError, "Missing zone_id for actuator command publish" if zone_id.blank?

    publish(actuator_command_topic(zone_id), command)
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

  def publish_node_config(node_id:, payload:)
    publish("greenhouse/nodes/#{node_id}/config", payload, retain: true)
  end

  def publish_config(payload)
    publish(system_config_topic, payload, retain: true)
  end

  def publish(topic, payload, retain: false)
    MQTT::Client.connect(mqtt_options) do |c|
      c.publish(topic, payload.to_json, retain)
    end
  end

  def mqtt_options
    options = {
      host: setting_value("mqtt_host", "MQTT_HOST", "localhost"),
      port: Integer(setting_value("mqtt_port", "MQTT_PORT", "1883"))
    }
    username = setting_value("mqtt_username", "MQTT_USERNAME", nil)
    password = setting_value("mqtt_password", "MQTT_PASSWORD", nil)
    options[:username] = username if username.present?
    options[:password] = password if password.present?
    options
  end

  def actuator_command_topic(zone_id)
    pattern = setting_value("command_topic", "MQTT_COMMAND_TOPIC", "greenhouse/zones/{zone_id}/actuator/command")
    pattern = "greenhouse/zones/{zone_id}/actuator/command" if pattern == "greenhouse/irrigation/commands"
    if pattern.include?("{zone_id}")
      pattern.gsub("{zone_id}", zone_id)
    elsif pattern.include?("+")
      pattern.sub("+", zone_id)
    else
      pattern
    end
  end

  def system_config_topic
    topic = setting_value("config_topic", "MQTT_CONFIG_TOPIC", "greenhouse/system/config/current")
    topic == "greenhouse/config/current" ? "greenhouse/system/config/current" : topic
  end

  def setting_value(attr, env_key, fallback)
    setting = ConnectionSetting.first
    value = setting&.public_send(attr)
    value = value.to_s if value.is_a?(Integer)
    value.presence || ENV.fetch(env_key, fallback)
  end
end
