require "test_helper"

class MqttClientTest < ActiveSupport::TestCase
  def with_publish_stub(callable)
    original = MqttClient.method(:publish)
    MqttClient.define_singleton_method(:publish, &callable)
    yield
  ensure
    MqttClient.define_singleton_method(:publish, &original)
  end

  test "publish_command requires a zone id" do
    error = assert_raises(ArgumentError) do
      MqttClient.publish_command(command: "start_watering")
    end

    assert_match "Missing zone_id", error.message
  end

  test "actuator_command_topic normalizes legacy command topic" do
    ConnectionSetting.create!(command_topic: "greenhouse/irrigation/commands")

    assert_equal(
      "greenhouse/zones/zone1/actuator/command",
      MqttClient.actuator_command_topic("zone1")
    )
  end

  test "actuator_command_topic substitutes wildcard patterns" do
    ConnectionSetting.create!(command_topic: "greenhouse/zones/+/actuator/command")

    assert_equal(
      "greenhouse/zones/zone1/actuator/command",
      MqttClient.actuator_command_topic("zone1")
    )
  end

  test "system_config_topic normalizes legacy config topic" do
    ConnectionSetting.create!(config_topic: "greenhouse/config/current")

    assert_equal "greenhouse/system/config/current", MqttClient.system_config_topic
  end

  test "actuator_config_topic uses dedicated retained config topic" do
    assert_equal "greenhouse/system/actuator/config/current", MqttClient.actuator_config_topic
  end

  test "request_reading publishes targeted retained node command" do
    calls = []

    with_publish_stub(->(topic, payload, retain: false) { calls << [topic, payload, retain] }) do
      MqttClient.request_reading(zone_id: "zone1", command_id: "cmd-1", node_id: "node-a")
    end

    assert_equal 1, calls.size
    topic, payload, retain = calls.first
    assert_equal "greenhouse/zones/zone1/command", topic
    assert_equal true, retain
    assert_equal "node-command/v1", payload[:schema_version]
    assert_equal "request_reading", payload[:command]
    assert_equal "cmd-1", payload[:command_id]
    assert_equal "node-a", payload[:node_id]
  end

  test "reboot_node publishes non retained targeted node command" do
    calls = []

    with_publish_stub(->(topic, payload, retain: false) { calls << [topic, payload, retain] }) do
      MqttClient.reboot_node(zone_id: "zone1", command_id: "cmd-2", node_id: "node-a")
    end

    assert_equal 1, calls.size
    topic, payload, retain = calls.first
    assert_equal "greenhouse/zones/zone1/command", topic
    assert_equal false, retain
    assert_equal "node-command/v1", payload[:schema_version]
    assert_equal "reboot", payload[:command]
    assert_equal "cmd-2", payload[:command_id]
    assert_equal "node-a", payload[:node_id]
  end

  test "mqtt_options prefer connection settings over environment fallbacks" do
    ENV["MQTT_HOST"] = "env-host"
    ENV["MQTT_PORT"] = "1999"
    ENV["MQTT_USERNAME"] = "env-user"
    ENV["MQTT_PASSWORD"] = "env-pass"
    ConnectionSetting.create!(
      mqtt_host: "db-host",
      mqtt_port: 1884,
      mqtt_username: "db-user",
      mqtt_password: "db-pass"
    )

    options = MqttClient.mqtt_options

    assert_equal "db-host", options[:host]
    assert_equal 1884, options[:port]
    assert_equal "db-user", options[:username]
    assert_equal "db-pass", options[:password]
  ensure
    ENV.delete("MQTT_HOST")
    ENV.delete("MQTT_PORT")
    ENV.delete("MQTT_USERNAME")
    ENV.delete("MQTT_PASSWORD")
  end
end
