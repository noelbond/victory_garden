require "test_helper"
require Rails.root.join("db/migrate/20260916100000_add_node_lifecycle_and_zone_sensor_device_binding").to_s

class AddNodeLifecycleAndZoneSensorDeviceBindingTest < ActiveSupport::TestCase
  def backfill
    AddNodeLifecycleAndZoneSensorDeviceBinding.new.send(:backfill_unambiguous_sensor_device_bindings)
  end

  def insert_legacy_node(zone:, node_id:, device_id:)
    timestamp = Time.current
    Node.insert_all!([
      {
        zone_id: zone.id,
        node_id: node_id,
        device_id: device_id,
        created_at: timestamp,
        updated_at: timestamp
      }
    ])
  end

  def insert_canonical_package(zone:, package_id:)
    4.times do |channel|
      insert_legacy_node(zone: zone, node_id: "#{package_id}-ch#{channel}", device_id: package_id)
    end
  end

  test "binds an exact canonical four-Node package" do
    zone = create(:zone)
    insert_canonical_package(zone: zone, package_id: "sensor-package-1")

    backfill

    assert_equal "sensor-package-1", zone.reload.sensor_device_id
  end

  test "leaves a three-Node package unbound" do
    zone = create(:zone)
    3.times do |channel|
      insert_legacy_node(zone: zone, node_id: "sensor-package-1-ch#{channel}", device_id: "sensor-package-1")
    end

    backfill

    assert_nil zone.reload.sensor_device_id
  end

  test "leaves a five-Node package unbound" do
    zone = create(:zone)
    insert_canonical_package(zone: zone, package_id: "sensor-package-1")
    insert_legacy_node(zone: zone, node_id: "sensor-package-1-sidecar", device_id: "sensor-package-1")

    backfill

    assert_nil zone.reload.sensor_device_id
  end

  test "leaves malformed channels unbound" do
    zone = create(:zone)
    insert_canonical_package(zone: zone, package_id: "sensor-package-1")
    Node.where(node_id: "sensor-package-1-ch3").update_all(node_id: "sensor-package-1-sidecar")

    backfill

    assert_nil zone.reload.sensor_device_id
  end

  test "leaves null-device extras unbound" do
    zone = create(:zone)
    insert_canonical_package(zone: zone, package_id: "sensor-package-1")
    insert_legacy_node(zone: zone, node_id: "legacy-node", device_id: nil)

    backfill

    assert_nil zone.reload.sensor_device_id
  end

  test "leaves mixed device identities unbound" do
    zone = create(:zone)
    insert_canonical_package(zone: zone, package_id: "sensor-package-1")
    Node.where(node_id: "sensor-package-1-ch3").update_all(device_id: "sensor-package-2")

    backfill

    assert_nil zone.reload.sensor_device_id
  end

  test "leaves an otherwise canonical package with an unsafe identity unbound" do
    zone = create(:zone)
    insert_canonical_package(zone: zone, package_id: "sensor\"package")

    backfill

    assert_nil zone.reload.sensor_device_id
  end

  test "does not promote a valid package through an unsafe legacy Zone identity" do
    zone = create(:zone)
    Zone.where(id: zone.id).update_all(zone_id: "zone\"unsafe")
    insert_canonical_package(zone: zone, package_id: "sensor-package-1")

    backfill

    assert_nil zone.reload.sensor_device_id
  end

  test "leaves a package represented in another Zone unbound everywhere" do
    first = create(:zone)
    second = create(:zone)
    insert_canonical_package(zone: first, package_id: "sensor-package-1")
    insert_legacy_node(zone: second, node_id: "sensor-package-1-legacy", device_id: "sensor-package-1")

    backfill

    assert_nil first.reload.sensor_device_id
    assert_nil second.reload.sensor_device_id
  end

  test "leaves a package unbound when another Zone is already bound to it" do
    candidate = create(:zone)
    existing_binding = create(:zone)
    insert_canonical_package(zone: candidate, package_id: "sensor-package-1")
    Zone.where(id: existing_binding.id).update_all(sensor_device_id: "sensor-package-1")

    backfill

    assert_nil candidate.reload.sensor_device_id
    assert_equal "sensor-package-1", existing_binding.reload.sensor_device_id
  end

  test "leaves unrelated empty Zones unbound and preserves existing bindings on repeat" do
    bindable = create(:zone)
    empty = create(:zone)
    already_bound = create(:zone)
    insert_canonical_package(zone: bindable, package_id: "sensor-package-1")
    insert_canonical_package(zone: already_bound, package_id: "sensor-package-2")
    Zone.where(id: already_bound.id).update_all(sensor_device_id: "sensor-package-2")

    backfill
    backfill

    assert_equal "sensor-package-1", bindable.reload.sensor_device_id
    assert_nil empty.reload.sensor_device_id
    assert_equal "sensor-package-2", already_bound.reload.sensor_device_id
  end
end
