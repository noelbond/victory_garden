require "test_helper"

class ConfigRepublishTest < ActiveSupport::TestCase
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

  test "zone update enqueues config republish for allowed_hours changes" do
    zone = create(:zone)

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(allowed_hours: { "start_hour" => "7", "end_hour" => "19" })
    end
  end

  test "zone update enqueues config republish for reading frequency changes" do
    zone = create(:zone)

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(publish_interval_ms: 300_000)
    end
  end

  test "node claim change enqueues config republish" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1", last_seen_at: Time.current)

    assert_enqueued_with(job: ConfigPublishJob) do
      node.update!(zone: zone)
    end
  end

  test "crop profile update enqueues config republish" do
    crop = create(:crop_profile)

    assert_enqueued_with(job: ConfigPublishJob) do
      crop.update!(dry_threshold: 35.0)
    end
  end
end
