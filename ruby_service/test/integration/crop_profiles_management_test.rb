require "test_helper"

class CropProfilesManagementTest < ActionDispatch::IntegrationTest
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

  test "onboarding links to custom crop profile creation" do
    get onboarding_path

    assert_response :success
    assert_includes response.body, "Custom Crop Profiles"
    assert_includes response.body, "Create Custom Profile"
  end

  test "creating a crop profile from onboarding redirects back to onboarding" do
    assert_difference("CropProfile.count", 1) do
      post crop_profiles_path, params: {
        return_to: onboarding_path,
        crop_profile: {
          crop_name: "Custom Basil",
          dry_threshold: 34.0,
          max_pulse_runtime_sec: 25,
          daily_max_runtime_sec: 150,
          climate_preference: "Warm",
          time_to_harvest_days: 55,
          notes: "Starts dry faster indoors"
        }
      }
    end

    assert_redirected_to onboarding_path
    crop = CropProfile.order(:id).last
    assert_equal "custom-basil", crop.crop_id
  end

  test "creating a crop profile rejects daily max runtime below max pulse runtime" do
    assert_no_difference("CropProfile.count") do
      post crop_profiles_path, params: {
        return_to: onboarding_path,
        crop_profile: {
          crop_name: "Broken Squash",
          dry_threshold: 30.0,
          max_pulse_runtime_sec: 60,
          daily_max_runtime_sec: 30,
          climate_preference: "Warm, sunny"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Profile could not be saved"
    assert_includes response.body, "Daily max runtime sec must be greater than or equal to max pulse runtime"
  end

  test "node page can switch the assigned zone to a different crop profile" do
    original_crop = create(:crop_profile, crop_name: "Tomato")
    replacement_crop = create(:crop_profile, crop_name: "Pepper")
    zone = create(:zone, crop_profile: original_crop)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)

    get node_path(node)

    assert_response :success
    assert_includes response.body, "Apply Profile To This Node's Zone"
    assert_includes response.body, "Edit Current Profile"

    assert_enqueued_with(job: ConfigPublishJob) do
      assert_enqueued_with(job: PublishNodeConfigJob) do
        patch crop_profile_node_path(node), params: { crop_profile_id: replacement_crop.id }
      end
    end

    assert_redirected_to node_path(node)
    assert_equal replacement_crop, zone.reload.crop_profile
  end

  test "creating a crop profile with a nonexistent apply_zone_id still creates the profile with plain notice" do
    assert_difference("CropProfile.count", 1) do
      post crop_profiles_path, params: {
        apply_zone_id: 99999,
        crop_profile: {
          crop_name: "Orphan Crop",
          dry_threshold: 30.0,
          max_pulse_runtime_sec: 30,
          daily_max_runtime_sec: 300,
          climate_preference: "Cool"
        }
      }
    end

    assert_redirected_to crop_profile_path(CropProfile.order(:id).last)
    assert_equal "Crop profile created.", flash[:notice]
  end

  test "creating a crop profile from a node page applies it to that node's zone" do
    original_crop = create(:crop_profile, crop_name: "Basil")
    zone = create(:zone, name: "Greenhouse Zone 2", crop_profile: original_crop)
    node = Node.create!(node_id: "demo-unclaimed-1", zone: zone, last_seen_at: Time.current)

    assert_difference("CropProfile.count", 1) do
      assert_enqueued_with(job: ConfigPublishJob) do
        assert_enqueued_with(job: PublishNodeConfigJob) do
          post crop_profiles_path, params: {
            return_to: node_path(node),
            apply_zone_id: zone.id,
            crop_profile: {
              crop_name: "Squash",
              dry_threshold: 30.0,
              max_pulse_runtime_sec: 60,
              daily_max_runtime_sec: 300,
              climate_preference: "Warm, sunny",
              notes: "Prefers deep watering"
            }
          }
        end
      end
    end

    created_crop = CropProfile.order(:id).last
    assert_redirected_to node_path(node)
    assert_equal created_crop, zone.reload.crop_profile

    follow_redirect!
    assert_response :success
    assert_includes response.body, "Current Profile:</strong> Squash"
    assert_select "option[selected]", text: "Squash"
  end
end
