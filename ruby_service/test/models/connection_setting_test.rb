require "test_helper"

class ConnectionSettingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "rejects irrigation line count below existing assignments" do
    create(:zone, irrigation_line: 3)
    setting = ConnectionSetting.new(irrigation_line_count: 2)

    assert_not setting.valid?
    assert_includes setting.errors[:irrigation_line_count], "must be at least 3 to keep existing zone assignments"
  end

  test "enqueues config publish when irrigation line count changes" do
    setting = ConnectionSetting.create!(irrigation_line_count: 2)

    assert_enqueued_with(job: ConfigPublishJob) do
      setting.update!(irrigation_line_count: 4)
    end
  end

  test "rejects irrigation line count of zero" do
    setting = ConnectionSetting.new(irrigation_line_count: 0)
    assert_not setting.valid?
    assert_includes setting.errors[:irrigation_line_count], "must be greater than 0"
  end

  test "rejects mqtt_port above the valid tcp range" do
    setting = ConnectionSetting.new(mqtt_port: 70_000)
    assert_not setting.valid?
    assert_includes setting.errors[:mqtt_port], "must be less than or equal to 65535"
  end

  test "accepts common mqtt host formats" do
    assert ConnectionSetting.new(mqtt_host: "localhost").valid?
    assert ConnectionSetting.new(mqtt_host: "broker.local").valid?
    assert ConnectionSetting.new(mqtt_host: "192.168.4.35").valid?
    assert ConnectionSetting.new(mqtt_host: "[fd00::1]").valid?
  end

  test "rejects malformed mqtt_host" do
    setting = ConnectionSetting.new(mqtt_host: "bad host name")
    assert_not setting.valid?
    assert_includes setting.errors[:mqtt_host], "must be a valid hostname, IPv4 address, or bracketed IPv6 address"
  end

  test "allows nil irrigation line count" do
    assert ConnectionSetting.new(irrigation_line_count: nil).valid?
  end

  test "accepts irrigation line count exactly matching the highest assigned zone line" do
    create(:zone, irrigation_line: 3)
    setting = ConnectionSetting.new(irrigation_line_count: 3)
    assert setting.valid?
  end

  test "does not enqueue config publish when other settings change" do
    setting = ConnectionSetting.create!(irrigation_line_count: 2, mqtt_host: "broker.local")

    assert_no_enqueued_jobs only: ConfigPublishJob do
      setting.update!(mqtt_host: "new-broker.local")
    end
  end

  test "stores mqtt_password encrypted while returning plaintext through the model" do
    setting = ConnectionSetting.create!(mqtt_host: "broker.local", mqtt_password: "secret123")

    assert_equal "secret123", setting.reload.mqtt_password
    raw_value = ConnectionSetting.connection.select_value(
      "SELECT mqtt_password FROM connection_settings WHERE id = #{setting.id}"
    )
    refute_equal "secret123", raw_value
    assert raw_value.present?
  end

  test "can still read legacy plaintext mqtt_password rows" do
    ConnectionSetting.connection.execute <<~SQL
      INSERT INTO connection_settings (mqtt_host, mqtt_password, created_at, updated_at)
      VALUES ('broker.local', 'legacy-secret', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL

    setting = ConnectionSetting.order(:id).last

    assert_equal "legacy-secret", setting.mqtt_password
  end
end
