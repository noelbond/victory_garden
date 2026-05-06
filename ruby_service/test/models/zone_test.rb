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

  test "rejects zero width allowed hours window" do
    zone = build(:zone, allowed_hours: { "start_hour" => 12, "end_hour" => 12 })

    assert_not zone.valid?
    assert_includes zone.errors[:allowed_hours], "start_hour and end_hour cannot be the same"
  end

  test "enqueues config publish when zone policy changes" do
    zone = create(:zone, allowed_hours: { "start_hour" => 6, "end_hour" => 20 })

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(allowed_hours: { "start_hour" => 7, "end_hour" => 19 })
    end
  end

  test "rejects irrigation line above configured line count" do
    ConnectionSetting.create!(irrigation_line_count: 2)
    zone = build(:zone, irrigation_line: 3)

    assert_not zone.valid?
    assert_includes zone.errors[:irrigation_line], "must be between 1 and 2"
  end

  test "rejects duplicate irrigation line assignments" do
    create(:zone, irrigation_line: 1)
    zone = build(:zone, irrigation_line: 1)

    assert_not zone.valid?
    assert_includes zone.errors[:irrigation_line], "has already been taken"
  end

  test "enqueues config publish when irrigation line changes" do
    zone = create(:zone, irrigation_line: 1)

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(irrigation_line: 2)
    end
  end

  test "defaults allowed hours and reading frequency" do
    zone = create(:zone)

    assert_equal({ "start_hour" => 6, "end_hour" => 20 }, zone.allowed_hours)
    assert_equal 3_600_000, zone.publish_interval_ms
  end

  test "enqueues config publish when reading frequency changes" do
    zone = create(:zone)

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(publish_interval_ms: 300_000)
    end
  end

  test "reading_frequency_hours converts ms to hours" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    assert_equal 1, zone.reading_frequency_hours

    zone.update!(publish_interval_ms: 7_200_000)
    assert_equal 2, zone.reading_frequency_hours
  end

  test "publish_interval_ms rejects zero" do
    zone = build(:zone, publish_interval_ms: 0)
    assert_not zone.valid?
    assert_includes zone.errors[:publish_interval_ms], "must be greater than 0"
  end

  test "publish_interval_ms rejects negative values" do
    zone = build(:zone, publish_interval_ms: -1)
    assert_not zone.valid?
    assert_includes zone.errors[:publish_interval_ms], "must be greater than 0"
  end

  test "publish_interval_ms rejects non-integer values" do
    zone = build(:zone, publish_interval_ms: 3600.5)
    assert_not zone.valid?
    assert_includes zone.errors[:publish_interval_ms], "must be an integer"
  end

  test "enqueues node config publish when zone policy changes" do
    zone = create(:zone, allowed_hours: { "start_hour" => 6, "end_hour" => 20 })
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      zone.update!(allowed_hours: { "start_hour" => 7, "end_hour" => 19 })
    end
  end

end
