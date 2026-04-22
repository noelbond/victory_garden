require "test_helper"

class CropProfileTest < ActiveSupport::TestCase
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

  test "enqueues config publish when irrigation policy changes" do
    crop = create(:crop_profile)

    assert_enqueued_with(job: ConfigPublishJob) do
      crop.update!(dry_threshold: 25.0)
    end
  end

  test "generates crop_id from crop name on create" do
    crop = CropProfile.create!(
      crop_name: "Custom Pepper",
      dry_threshold: 28.5,
      max_pulse_runtime_sec: 30,
      daily_max_runtime_sec: 180
    )

    assert_equal "custom-pepper", crop.crop_id
  end

  test "generates unique crop_id for duplicate names" do
    create(:crop_profile, crop_id: "custom-pepper", crop_name: "Custom Pepper")

    crop = CropProfile.create!(
      crop_name: "Custom Pepper",
      dry_threshold: 31.0,
      max_pulse_runtime_sec: 35,
      daily_max_runtime_sec: 200
    )

    assert_equal "custom-pepper-2", crop.crop_id
  end

  test "enqueues node config publish when assigned crop profile changes" do
    crop = create(:crop_profile)
    zone = create(:zone, crop_profile: crop)
    Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    assert_enqueued_with(job: PublishNodeConfigJob) do
      crop.update!(dry_threshold: 25.0)
    end
  end
end
