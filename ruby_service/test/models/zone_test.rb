require "test_helper"

class ZoneTest < ActiveSupport::TestCase
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

  test "rejects out of range allowed hours" do
    zone = build(:zone, allowed_hours: { "start_hour" => 24, "end_hour" => 8 })

    assert_not zone.valid?
    assert_includes zone.errors[:allowed_hours], "start_hour must be an integer between 0 and 23"
  end

  test "rejects partial allowed hours" do
    zone = build(:zone, allowed_hours: { "start_hour" => 6 })

    assert_not zone.valid?
    assert_includes zone.errors[:allowed_hours], "must include start_hour and end_hour"
  end

  test "enqueues config publish when zone policy changes" do
    zone = create(:zone, allowed_hours: { "start_hour" => 6, "end_hour" => 20 })

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(allowed_hours: { "start_hour" => 7, "end_hour" => 19 })
    end
  end
end
