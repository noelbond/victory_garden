require "test_helper"

class OnboardingTest < ActionDispatch::IntegrationTest
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

  test "assigning a node during onboarding shows the node's friendly name in the notice" do
    zone = create(:zone, name: "Greenhouse Zone 1")
    node = Node.create!(node_id: "sensor-zone1-ch0", last_seen_at: Time.current)

    patch onboarding_assignment_path, params: { node_id: node.id, zone_id: zone.id }

    assert_response :redirect
    assert_equal "Greenhouse Zone 1 node 1 assigned to Greenhouse Zone 1.", flash[:notice]
    assert_equal zone, node.reload.zone
    assert_equal "Greenhouse Zone 1 node 1", node.name
  end
end
