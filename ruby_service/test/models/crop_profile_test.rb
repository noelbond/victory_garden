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
end
