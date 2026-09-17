require "test_helper"

class ManualWateringActionsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
    @crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    @zone = create(:zone, zone_id: "zone1")
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "zone-only stop fails closed without publishing or creating an event" do
    assert_no_enqueued_jobs only: CommandPublishJob do
      post stop_watering_zone_path(@zone)
    end

    assert_redirected_to zone_path(@zone)
    assert_equal "Zone-level stopping is unavailable until the explicit stop-all operation is implemented.", flash[:alert]
    assert_equal 0, WateringEvent.count
  end
end
