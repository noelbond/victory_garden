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
    node = Node.create!(node_id: "sensor-zone1-ch0", zone: create(:zone), last_seen_at: Time.current)

    patch onboarding_assignment_path, params: { node_id: node.id, zone_id: zone.id }

    assert_response :redirect
    assert_equal "Greenhouse Zone 1 Node 1 assigned to Greenhouse Zone 1.", flash[:notice]
    assert_equal zone, node.reload.zone
    assert_nil node.name
  end

  test "onboarding assignment cannot split a sensor package" do
    source_zone = create(:zone)
    target_zone = create(:zone)
    SensorZoneProvisioner.call(zone: source_zone, sensor_device_id: "sensor-zone1")
    channels = source_zone.nodes.order(:node_id).to_a

    patch onboarding_assignment_path, params: { node_id: channels.first.id, zone_id: target_zone.id }

    assert_response :redirect
    assert_match "individual channel reassignment is not allowed", flash[:alert]
    assert_equal [source_zone.id], channels.map { |node| node.reload.zone_id }.uniq
  end

  test "zone-only water now fails closed without publishing a start command" do
    zone = create(:zone)

    assert_no_enqueued_jobs only: CommandPublishJob do
      post onboarding_water_now_path, params: { zone_id: zone.id }
    end

    assert_response :redirect
    assert_includes response.location, "step=watering"
    assert_equal "Choose a configured plant node before testing watering.", flash[:alert]
    assert_equal 0, WateringEvent.count
  end

  test "zone onboarding provisions the canonical four Nodes before telemetry" do
    get onboarding_path(step: "zone")

    assert_response :success
    assert_includes response.body, "Pump/relay assignments are configured per plant sensor Node."

    patch onboarding_zone_path, params: {
      zone: {
        name: "Node Routed Zone",
        active: true,
        publish_interval_ms: 7_200_000
      }
    }

    assert_redirected_to onboarding_path(step: "detected_node", sensor_board: "pico_w", actuator_board: "pico_w")
    zone = Zone.find_by!(name: "Node Routed Zone")
    assert_equal 7_200_000, zone.publish_interval_ms
    assert_equal "sensor-#{zone.zone_id}", zone.sensor_device_id
    assert_equal Node.canonical_package_node_ids(zone.sensor_device_id), zone.nodes.order(:node_id).pluck(:node_id)
    assert zone.canonical_sensor_package_nodes?
    assert zone.nodes.all? { |node| node.last_seen_at.nil? }

    get onboarding_path(step: "detected_node")

    assert_response :success
    assert_includes response.body, "Waiting For Sensor Node"
  end

  test "zone onboarding remains on the form and rolls back when package provisioning fails" do
    zone = create(:zone, name: "Existing Zone")
    legacy = Node.create!(node_id: "legacy-node", zone: zone, irrigation_line: 8, last_seen_at: nil)

    patch onboarding_zone_path, params: {
      zone: { name: "Changed Name", active: true, publish_interval_ms: 7_200_000 }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "contains unrelated node legacy-node"
    assert_equal "Existing Zone", zone.reload.name
    assert_nil zone.sensor_device_id
    assert_equal [legacy.node_id], zone.nodes.pluck(:node_id)
    assert_equal 0, Node.where(device_id: "sensor-#{zone.zone_id}").count
  end

  test "resubmitting a correctly provisioned onboarding Zone is idempotent and telemetry reconciles it" do
    patch onboarding_zone_path, params: {
      zone: { name: "Node Routed Zone", active: true, publish_interval_ms: 7_200_000 }
    }
    zone = Zone.find_by!(name: "Node Routed Zone")
    original_node_ids = zone.nodes.order(:node_id).pluck(:node_id)
    original_lines = zone.nodes.order(:node_id).pluck(:irrigation_line)

    patch onboarding_zone_path, params: {
      zone: { name: "Node Routed Zone", active: true, publish_interval_ms: 7_200_000 }
    }

    assert_redirected_to onboarding_path(step: "detected_node", sensor_board: "pico_w", actuator_board: "pico_w")
    assert_equal original_node_ids, zone.reload.nodes.order(:node_id).pluck(:node_id)
    assert_equal original_lines, zone.nodes.order(:node_id).pluck(:irrigation_line)

    node = zone.nodes.order(:node_id).first
    payload = JSON.parse(File.read(Rails.root.join("..", "contracts", "examples", "node-state-v1.json"))).merge(
      "node_id" => node.node_id,
      "device_id" => zone.sensor_device_id,
      "zone_id" => zone.zone_id
    )
    SensorIngestor.new(payload).call

    assert node.reload.last_seen_at.present?
    assert_equal 4, zone.nodes.count
  end

  test "onboarding reports an overlong generated package identity without binding or Nodes" do
    zone = create(:zone, zone_id: "z" * 21, name: "Existing Zone")

    patch onboarding_zone_path, params: {
      zone: { name: "Changed Name", active: true, publish_interval_ms: 7_200_000 }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "at most #{SensorIdentityContract::MAX_PACKAGE_ID_BYTES} bytes"
    assert_equal "Existing Zone", zone.reload.name
    assert_nil zone.sensor_device_id
    assert_equal 0, zone.nodes.count
  end
end
