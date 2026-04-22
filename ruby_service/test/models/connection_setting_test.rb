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
end
