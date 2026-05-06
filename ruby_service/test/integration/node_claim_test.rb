require "test_helper"

class NodeClaimTest < ActionDispatch::IntegrationTest
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

  test "claiming a node assigns it to the zone and enqueues config publish" do
    zone = create(:zone)
    node = Node.create!(node_id: "unclaimed-1", last_seen_at: Time.current)

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      patch claim_node_path(node), params: { zone_id: zone.id }
    end

    assert_redirected_to node_path(node)
    assert_equal "Node claimed for #{zone.zone_id}.", flash[:notice]
    assert_equal zone, node.reload.zone
  end

  test "claiming a node with a named zone uses the zone name in the notice" do
    zone = create(:zone, name: "Greenhouse Bed A")
    node = Node.create!(node_id: "unclaimed-2", last_seen_at: Time.current)

    patch claim_node_path(node), params: { zone_id: zone.id }

    assert_equal "Node claimed for Greenhouse Bed A.", flash[:notice]
  end

  test "claiming replaces a previously claimed zone" do
    original_zone = create(:zone)
    new_zone = create(:zone)
    node = Node.create!(node_id: "already-claimed", zone: original_zone, last_seen_at: Time.current)

    patch claim_node_path(node), params: { zone_id: new_zone.id }

    assert_redirected_to node_path(node)
    assert_equal new_zone, node.reload.zone
  end

  test "unclaiming a node removes the zone and enqueues config publish" do
    zone = create(:zone)
    node = Node.create!(node_id: "claimed-node", zone: zone, last_seen_at: Time.current)

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      patch unclaim_node_path(node)
    end

    assert_redirected_to nodes_path
    assert_equal "Node unclaimed.", flash[:notice]
    assert_nil node.reload.zone
  end

  test "unclaiming an already unclaimed node redirects cleanly without enqueuing" do
    node = Node.create!(node_id: "never-claimed", last_seen_at: Time.current)

    assert_no_enqueued_jobs only: PublishNodeConfigJob do
      patch unclaim_node_path(node)
    end

    assert_redirected_to nodes_path
  end
end
