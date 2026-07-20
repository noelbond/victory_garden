class ConnectionSettingDefaults
  def self.apply!(setting)
    new(setting).apply!
  end

  def self.mqtt_username_for(setting)
    new(setting).effective_mqtt_username
  end

  def self.mqtt_password_for(setting)
    new(setting).effective_mqtt_password
  end

  def initialize(setting)
    @setting = setting
  end

  def apply!
    @setting.mqtt_host = ENV["MQTT_HOST"].presence || "127.0.0.1" if @setting.mqtt_host.blank?
    @setting.mqtt_port = (ENV["MQTT_PORT"].presence || 1883).to_i if @setting.mqtt_port.blank?
    # The Pi-managed broker credentials are authoritative for first-run setup.
    # The desktop installer provisions Pico nodes with these exact values, so
    # allowing arbitrary setup-time overrides here would break broker auth.
    @setting.mqtt_username = effective_mqtt_username
    @setting.mqtt_password = effective_mqtt_password
    @setting.readings_topic = "greenhouse/zones/+/nodes/+/state" if @setting.readings_topic.blank?
    @setting.actuators_topic = "greenhouse/zones/+/actuator/status" if @setting.actuators_topic.blank?
    @setting.command_topic = "greenhouse/zones/{zone_id}/actuator/command" if @setting.command_topic.blank?
    @setting.config_topic = "greenhouse/system/config/current" if @setting.config_topic.blank?
    @setting.bluetooth_enabled = false if @setting.bluetooth_enabled.nil?
    @setting
  end

  def effective_mqtt_username
    ENV["MQTT_USERNAME"].presence || @setting.mqtt_username.presence || "victory_garden"
  end

  def effective_mqtt_password
    ENV["MQTT_PASSWORD"].presence || @setting.mqtt_password
  end
end
