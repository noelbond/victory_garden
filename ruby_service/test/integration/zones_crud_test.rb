require "test_helper"

class ZonesCrudTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
    @crop = create(:crop_profile)
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "creating a zone redirects to zones list with notice" do
    post zones_path, params: {
      zone: { name: "New Zone", crop_profile_id: @crop.id }
    }

    assert_redirected_to zones_path
    assert_equal "Zone created.", flash[:notice]
    assert Zone.find_by(name: "New Zone")
  end

  test "creating a zone with invalid params renders new with error" do
    # zone_id uniqueness is the one validation we can deliberately break
    existing = create(:zone, zone_id: "dup-zone")
    # simulate the controller path: pass an explicit zone_id via the model
    # using a malformed crop_profile_id triggers the belongs_to validation
    post zones_path, params: {
      zone: { name: "X" * 101, crop_profile_id: @crop.id }
    }

    assert_response :unprocessable_entity
  end

  test "updating a zone redirects to the zone show page" do
    zone = create(:zone, name: "Old Name")

    patch zone_path(zone), params: { zone: { name: "New Name" } }

    assert_redirected_to zone_path(zone)
    assert_equal "Zone updated.", flash[:notice]
    assert_equal "New Name", zone.reload.name
  end

  test "updating a zone with invalid params renders edit" do
    zone = create(:zone)

    patch zone_path(zone), params: {
      zone: { publish_interval_ms: 0 }
    }

    assert_response :unprocessable_entity
  end

  test "updating publish_interval_ms saves and redirects to zone show" do
    zone = create(:zone, publish_interval_ms: 3_600_000)

    patch zone_path(zone), params: { zone: { publish_interval_ms: 7_200_000 } }

    assert_redirected_to zone_path(zone)
    assert_equal 7_200_000, zone.reload.publish_interval_ms
  end

  test "destroying a zone redirects to zones list" do
    zone = create(:zone)

    delete zone_path(zone)

    assert_redirected_to zones_path
    assert_nil Zone.find_by(id: zone.id)
  end

  test "toggling a zone active state redirects to zone show" do
    zone = create(:zone)
    original = zone.active

    post toggle_active_zone_path(zone)

    assert_redirected_to zone_path(zone)
    assert_equal !original, zone.reload.active
  end
end
