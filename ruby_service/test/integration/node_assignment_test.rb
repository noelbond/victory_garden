require "test_helper"

class NodeAssignmentTest < ActionDispatch::IntegrationTest
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

  test "assigning a node attaches it to the zone and enqueues config publish" do
    zone = create(:zone)
    node = Node.create!(node_id: "unassigned-1", last_seen_at: Time.current)

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      patch assign_node_path(node), params: { zone_id: zone.id }
    end

    assert_redirected_to node_path(node)
    assert_equal "Node assigned to #{zone.name.presence || zone.zone_id}.", flash[:notice]
    assert_equal zone, node.reload.zone
  end

  test "assigning a node with a named zone uses the zone name in the notice" do
    zone = create(:zone, name: "Greenhouse Bed A")
    node = Node.create!(node_id: "unassigned-2", last_seen_at: Time.current)

    patch assign_node_path(node), params: { zone_id: zone.id }

    assert_equal "Node assigned to Greenhouse Bed A.", flash[:notice]
  end

  test "assigning replaces a previously assigned zone" do
    original_zone = create(:zone)
    new_zone = create(:zone)
    node = Node.create!(node_id: "already-assigned", zone: original_zone, last_seen_at: Time.current)

    patch assign_node_path(node), params: { zone_id: new_zone.id }

    assert_redirected_to node_path(node)
    assert_equal new_zone, node.reload.zone
  end

  test "unassigning a node removes the zone and enqueues config publish" do
    zone = create(:zone)
    node = Node.create!(node_id: "assigned-node", zone: zone, last_seen_at: Time.current)

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      patch unassign_node_path(node)
    end

    assert_redirected_to nodes_path
    assert_equal "Node unassigned.", flash[:notice]
    assert_nil node.reload.zone
  end

  test "unassigning an already unassigned node redirects cleanly without enqueuing" do
    node = Node.create!(node_id: "never-assigned", last_seen_at: Time.current)

    assert_no_enqueued_jobs only: PublishNodeConfigJob do
      patch unassign_node_path(node)
    end

    assert_redirected_to nodes_path
  end
end
