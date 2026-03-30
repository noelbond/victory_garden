require "test_helper"

class MqttConsumerTest < ActiveSupport::TestCase
  test "parse_json ignores empty retained clears" do
    consumer = MqttConsumer.new

    assert_nil consumer.send(:parse_json, "")
    assert_nil consumer.send(:parse_json, nil)
  end
end

