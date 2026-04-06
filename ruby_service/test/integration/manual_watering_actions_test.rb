require "test_helper"

class ManualWateringActionsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
    @crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    @zone = create(:zone, zone_id: "zone1", crop_profile: @crop)
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "water now queues a manual watering event and publish job" do
    assert_enqueued_jobs 1, only: CommandPublishJob do
      post water_now_zone_path(@zone)
    end

    assert_redirected_to zone_path(@zone)
    event = WateringEvent.order(:id).last
    assert_equal @zone, event.zone
    assert_equal "start_watering", event.command
    assert_equal 45, event.runtime_seconds
    assert_equal "manual_trigger", event.reason
    assert_equal "queued", event.status
    assert event.idempotency_key.present?
  end

  test "stop watering queues a manual stop event and publish job" do
    assert_enqueued_jobs 1, only: CommandPublishJob do
      post stop_watering_zone_path(@zone)
    end

    assert_redirected_to zone_path(@zone)
    event = WateringEvent.order(:id).last
    assert_equal @zone, event.zone
    assert_equal "stop_watering", event.command
    assert_nil event.runtime_seconds
    assert_equal "manual_stop", event.reason
    assert_equal "queued", event.status
    assert event.idempotency_key.present?
  end
end
