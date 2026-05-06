require "test_helper"

class ConfigPublishButtonTest < ActionDispatch::IntegrationTest
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

  test "html publish config request from settings enqueues config publish and redirects back" do
    get settings_path
    assert_response :success

    assert_enqueued_with(job: ConfigPublishJob) do
      post admin_publish_config_path
    end

    assert_redirected_to settings_path
  end
end
