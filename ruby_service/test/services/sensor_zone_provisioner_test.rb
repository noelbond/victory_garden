require "test_helper"

class SensorZoneProvisionerTest < ActiveSupport::TestCase
  def provision(zone, device_id)
    SensorZoneProvisioner.call(zone: zone, sensor_device_id: device_id)
  end

  test "creates four stable pre-telemetry channels with global lines" do
    zone = create(:zone, zone_id: "zone1")

    provision(zone, "sensor-zone1")

    nodes = zone.reload.nodes.order(:node_id)
    assert_equal %w[sensor-zone1-ch0 sensor-zone1-ch1 sensor-zone1-ch2 sensor-zone1-ch3], nodes.pluck(:node_id)
    assert_equal [1, 2, 3, 4], nodes.pluck(:irrigation_line).sort
    assert_equal "sensor-zone1", zone.sensor_device_id
    assert nodes.all?(&:active?)
    assert nodes.all? { |node| node.last_seen_at.nil? }
    assert nodes.all? { |node| node.crop_profile.nil? }
    assert_equal ["sensor-zone1"], nodes.pluck(:device_id).uniq
  end

  test "allocates globally and reuses the lowest gaps" do
    first = create(:zone, zone_id: "zone1")
    second = create(:zone, zone_id: "zone2")
    provision(first, "sensor-zone1")

    legacy_zone = create(:zone, zone_id: "legacy")
    [5, 7, 8, 9].each do |line|
      Node.create!(node_id: "legacy-#{line}", zone: legacy_zone, irrigation_line: line, last_seen_at: nil)
    end
    gap = Node.create!(node_id: "legacy-gap", zone: legacy_zone, irrigation_line: 6, last_seen_at: nil)
    gap.destroy!

    provision(second, "sensor-zone2")
    assert_equal [6, 10, 11, 12], second.nodes.pluck(:irrigation_line).sort
  end

  test "is idempotent and preserves explicit node setup" do
    zone = create(:zone, zone_id: "zone1")
    provision(zone, "sensor-zone1")
    node = zone.nodes.find_by!(node_id: "sensor-zone1-ch0")
    crop = create(:crop_profile)
    node.update!(crop_profile: crop, last_seen_at: Time.current, active: false)

    provision(zone, "sensor-zone1")

    assert_equal 4, zone.nodes.count
    assert_equal crop, node.reload.crop_profile
    assert node.last_seen_at.present?
    assert node.active?
    assert_equal [1, 2, 3, 4], zone.nodes.pluck(:irrigation_line).sort
  end

  test "completes a correct partial package to exactly four channels" do
    zone = create(:zone, zone_id: "zone1")
    %w[ch0 ch1].each do |channel|
      Node.create!(node_id: "sensor-zone1-#{channel}", device_id: "sensor-zone1", zone: zone, last_seen_at: nil)
    end

    provision(zone, "sensor-zone1")

    assert_equal %w[sensor-zone1-ch0 sensor-zone1-ch1 sensor-zone1-ch2 sensor-zone1-ch3], zone.reload.nodes.order(:node_id).pluck(:node_id)
    assert_equal "sensor-zone1", zone.sensor_device_id
  end

  test "rejects unrelated legacy topology before binding or allocation" do
    zone = create(:zone, zone_id: "zone1", sensor_device_id: nil)
    legacy = Node.create!(node_id: "legacy-node", zone: zone, irrigation_line: 8, last_seen_at: Time.current)

    error = assert_raises(SensorZoneProvisioner::ProvisioningError) { provision(zone, "sensor-zone1") }

    assert_match "contains unrelated node legacy-node", error.message
    assert_nil zone.reload.sensor_device_id
    assert_equal [legacy.node_id], zone.nodes.pluck(:node_id)
    assert_equal 8, legacy.reload.irrigation_line
    assert_equal 0, Node.where(device_id: "sensor-zone1").count
  end

  test "rejects another package, a fifth channel, and malformed package identity in the target Zone" do
    other_package_zone = create(:zone, zone_id: "zone-other")
    Node.create!(node_id: "sensor-zone2-ch0", device_id: "sensor-zone2", zone: other_package_zone, last_seen_at: nil)
    assert_raises(SensorZoneProvisioner::ProvisioningError) { provision(other_package_zone, "sensor-zone1") }
    assert_equal ["sensor-zone2-ch0"], other_package_zone.nodes.pluck(:node_id)

    fifth_channel_zone = create(:zone, zone_id: "zone-fifth")
    Node.create!(node_id: "sensor-zone3-ch4", device_id: "sensor-zone3", zone: fifth_channel_zone, last_seen_at: nil)
    assert_raises(SensorZoneProvisioner::ProvisioningError) { provision(fifth_channel_zone, "sensor-zone3") }
    assert_equal ["sensor-zone3-ch4"], fifth_channel_zone.nodes.pluck(:node_id)

    malformed_zone = create(:zone, zone_id: "zone-malformed")
    Node.create!(node_id: "sensor-zone4-sidecar", device_id: "sensor-zone4", zone: malformed_zone, last_seen_at: nil)
    assert_raises(SensorZoneProvisioner::ProvisioningError) { provision(malformed_zone, "sensor-zone4") }
    assert_equal ["sensor-zone4-sidecar"], malformed_zone.nodes.pluck(:node_id)
  end

  test "rejects a package already bound to another zone" do
    first = create(:zone, zone_id: "zone1")
    second = create(:zone, zone_id: "zone2")
    provision(first, "sensor-zone1")

    error = assert_raises(SensorZoneProvisioner::ProvisioningError) { provision(second, "sensor-zone1") }
    assert_match(/already bound|assigned to another zone/, error.message)
    assert_equal 0, second.nodes.count
  end

  test "rejects a channel identity presented as a package identity" do
    zone = create(:zone, zone_id: "zone1")

    error = assert_raises(SensorZoneProvisioner::ProvisioningError) { provision(zone, "sensor-zone1-ch0") }
    assert_match "must not include a channel suffix", error.message
    assert_equal 0, zone.nodes.count
  end

  test "rejects identities that cannot fit canonical firmware Node IDs before mutating topology" do
    zone = create(:zone, zone_id: "zone1")
    overlong_package = "a" * (SensorIdentityContract::MAX_PACKAGE_ID_BYTES + 1)

    error = assert_raises(SensorZoneProvisioner::ProvisioningError) { provision(zone, overlong_package) }

    assert_match "at most #{SensorIdentityContract::MAX_PACKAGE_ID_BYTES} bytes", error.message
    assert_nil zone.reload.sensor_device_id
    assert_equal 0, zone.nodes.count
    assert_equal 0, Node.where.not(irrigation_line: nil).count
  end

  test "accepts the maximum package identity that produces a firmware-sized canonical Node ID" do
    zone = create(:zone, zone_id: "zone1")
    package_id = "a" * SensorIdentityContract::MAX_PACKAGE_ID_BYTES

    provision(zone, package_id)

    assert_equal package_id, zone.reload.sensor_device_id
    assert_equal SensorIdentityContract.canonical_node_ids(package_id), zone.nodes.order(:node_id).pluck(:node_id)
    assert_equal SensorIdentityContract::MAX_FIRMWARE_ID_BYTES, zone.nodes.order(:node_id).last.node_id.bytesize
  end

  test "rejects firmware-unsafe package identities before binding or allocation" do
    ["sensor/package", "sensor+package", "sensor#package", "sensor\"package", "sensor\\package", "sensor]package", "sensor}package", "sensor,package", "sensor:package", "sensor.package", " package", "package ", "\tpackage", "package\n", "pack age", "sensor\tpackage"].each_with_index do |package_id, index|
      zone = create(:zone, zone_id: "zone#{index}")
      node_count = Node.count
      assigned_line_count = Node.where.not(irrigation_line: nil).count

      error = assert_raises(SensorZoneProvisioner::ProvisioningError) { provision(zone, package_id) }

      assert_match "only ASCII letters", error.message
      assert_nil zone.reload.sensor_device_id
      assert_equal node_count, Node.count
      assert_equal assigned_line_count, Node.where.not(irrigation_line: nil).count
    end
  end

  test "fills a precreated channel and first telemetry updates it without duplication" do
    zone = create(:zone, zone_id: "zone1")
    provision(zone, "sensor-zone1")
    node = zone.nodes.find_by!(node_id: "sensor-zone1-ch2")
    payload = JSON.parse(File.read(Rails.root.join("..", "contracts", "examples", "node-state-v1.json"))).merge(
      "node_id" => node.node_id,
      "device_id" => "sensor-zone1",
      "zone_id" => "zone1"
    )

    SensorIngestor.new(payload).call

    assert_equal 4, zone.nodes.count
    assert_equal node.id, Node.find_by!(node_id: node.node_id).id
    assert node.reload.last_seen_at.present?
  end

  test "telemetry conflicts preserve authoritative zone, package, crop, and line" do
    zone = create(:zone, zone_id: "zone1")
    crop = create(:crop_profile)
    provision(zone, "sensor-zone1")
    node = zone.nodes.find_by!(node_id: "sensor-zone1-ch0")
    node.update!(crop_profile: crop)
    payload = JSON.parse(File.read(Rails.root.join("..", "contracts", "examples", "node-state-v1.json"))).merge(
      "node_id" => node.node_id,
      "device_id" => "wrong-package",
      "zone_id" => "wrong-zone"
    )

    SensorIngestor.new(payload).call

    node.reload
    assert_equal zone, node.zone
    assert_equal "sensor-zone1", node.device_id
    assert_equal crop, node.crop_profile
    assert_equal 1, node.irrigation_line
    assert_equal "wrong-zone", node.reported_zone_id
  end

  test "a pre-existing irrigation line is protected by the database uniqueness constraint" do
    zone = create(:zone)
    Node.create!(node_id: "existing", zone: zone, irrigation_line: 1)
    assert_raises(ActiveRecord::RecordInvalid) { Node.create!(node_id: "duplicate", zone: zone, irrigation_line: 1) }
  end
end
