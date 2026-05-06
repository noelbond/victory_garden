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
end
