require "test_helper"

class NodeTest < ActiveSupport::TestCase
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

  def valid_attrs
    {
      node_id: "pico-w-test-001",
      zone: create(:zone),
      last_seen_at: Time.current
    }
  end

  test "valid with required fields only" do
    assert Node.new(valid_attrs).valid?
  end

  test "requires node_id" do
    node = Node.new(valid_attrs.merge(node_id: nil))
    assert_not node.valid?
    assert_includes node.errors[:node_id], "can't be blank"
  end

  test "enforces the exact firmware identity contract for direct Node mutations" do
    node = Node.create!(valid_attrs.merge(node_id: "node-safe"))

    assert_not node.update(node_id: "node\"unsafe")
    assert_includes node.errors[:node_id], "Node identity must use only ASCII letters, digits, hyphen, or underscore for firmware compatibility."
    assert_equal "node-safe", node.reload.node_id

    assert_not node.update(node_id: "n" * 32)
    assert_includes node.errors[:node_id], "Node identity must be at most 31 bytes for firmware compatibility."
    assert_equal "node-safe", node.reload.node_id
  end

  test "enforces the exact firmware package identity contract for direct device mutations" do
    node = Node.create!(valid_attrs.merge(node_id: "node-safe"))

    assert_not node.update(device_id: "package\"unsafe")
    assert_includes node.errors[:device_id], "Sensor package identity must use only ASCII letters, digits, hyphen, or underscore for firmware compatibility."
    assert_nil node.reload.device_id

    assert_not node.update(device_id: "p" * (SensorIdentityContract::MAX_PACKAGE_ID_BYTES + 1))
    assert_includes node.errors[:device_id], "Sensor package identity must be at most 27 bytes for firmware compatibility."
    assert_nil node.reload.device_id
  end

  test "accepts maximum-length firmware-safe Node and package identities unchanged" do
    zone = create(:zone, zone_id: "Z" * SensorIdentityContract::MAX_FIRMWARE_ID_BYTES)
    package_id = "P" * SensorIdentityContract::MAX_PACKAGE_ID_BYTES
    node = Node.create!(
      node_id: "N" * SensorIdentityContract::MAX_FIRMWARE_ID_BYTES,
      device_id: package_id,
      zone: zone,
      last_seen_at: nil
    )

    assert_equal "N" * 31, node.reload.node_id
    assert_equal package_id, node.device_id
  end

  test "allows a logical node that has never reported telemetry" do
    node = Node.new(valid_attrs.merge(last_seen_at: nil))

    assert node.valid?
    assert_nil node.last_seen_at
  end

  test "defaults a node to active" do
    assert Node.new(valid_attrs).active?
  end

  test "allows a node to be marked inactive" do
    node = Node.create!(valid_attrs)

    assert node.update(active: false)
    assert_not node.reload.active?
  end

  test "changing active state preserves node identity, assignment, crop, line, and readings" do
    zone = create(:zone)
    crop = create(:crop_profile)
    node = Node.create!(valid_attrs.merge(zone: zone, crop_profile: crop, irrigation_line: 7))
    SensorReading.create!(zone: zone, node_id: node.node_id, recorded_at: Time.current, moisture_raw: 500)

    node.update!(active: false)

    assert_equal "pico-w-test-001", node.reload.node_id
    assert_equal zone, node.zone
    assert_equal crop, node.crop_profile
    assert_equal 7, node.irrigation_line
    assert_equal 1, SensorReading.where(node_id: node.node_id).count
  end

  test "rejects duplicate node_id" do
    Node.create!(valid_attrs)
    node = Node.new(valid_attrs)
    assert_not node.valid?
    assert_includes node.errors[:node_id], "has already been taken"
  end

  test "rejects battery_voltage above 10" do
    node = Node.new(valid_attrs.merge(battery_voltage: 10.1))
    assert_not node.valid?
    assert_includes node.errors[:battery_voltage], "must be less than or equal to 10"
  end

  test "rejects negative battery_voltage" do
    node = Node.new(valid_attrs.merge(battery_voltage: -0.1))
    assert_not node.valid?
    assert_includes node.errors[:battery_voltage], "must be greater than or equal to 0"
  end

  test "accepts battery_voltage at boundary values" do
    assert Node.new(valid_attrs.merge(battery_voltage: 0)).valid?
    assert Node.new(valid_attrs.merge(battery_voltage: 10)).valid?
  end

  test "rejects positive wifi_rssi" do
    node = Node.new(valid_attrs.merge(wifi_rssi: 1))
    assert_not node.valid?
    assert_includes node.errors[:wifi_rssi], "must be less than or equal to 0"
  end

  test "rejects wifi_rssi below -130" do
    node = Node.new(valid_attrs.merge(wifi_rssi: -131))
    assert_not node.valid?
    assert_includes node.errors[:wifi_rssi], "must be greater than or equal to -130"
  end

  test "accepts wifi_rssi at boundary values" do
    assert Node.new(valid_attrs.merge(wifi_rssi: 0)).valid?
    assert Node.new(valid_attrs.merge(wifi_rssi: -130)).valid?
  end

  test "rejects invalid config_status" do
    node = Node.new(valid_attrs.merge(config_status: "ready"))
    assert_not node.valid?
    assert_includes node.errors[:config_status], "is not included in the list"
  end

  test "accepts all valid config_status values" do
    %w[pending applied error unassigned].each do |status|
      assert Node.new(valid_attrs.merge(config_status: status)).valid?,
             "expected config_status #{status.inspect} to be valid"
    end
  end

  test "display name falls back to stable node id for a malformed channel id" do
    node = Node.new(valid_attrs)

    assert_equal "pico-w-test-001", node.display_name
  end

  test "blank custom name derives a display name from the zone and production channel" do
    zone = create(:zone, name: "Tomatoes")

    channels = 4.times.map do |channel|
      Node.create!(node_id: "sensor-zone1-ch#{channel}", zone: zone, name: nil, last_seen_at: nil)
    end

    assert_equal ["Tomatoes Node 1", "Tomatoes Node 2", "Tomatoes Node 3", "Tomatoes Node 4"], channels.map(&:display_name)
    assert_equal [nil, nil, nil, nil], channels.map(&:name)
  end

  test "custom name overrides the derived display name" do
    zone = create(:zone, name: "Tomatoes")
    node = Node.create!(node_id: "sensor-zone1-ch0", zone: zone, name: "Cherry Tomato", last_seen_at: nil)

    assert_equal "Cherry Tomato", node.display_name
  end

  test "blank zone label uses the stable zone id in the derived display name" do
    zone = create(:zone, name: nil, zone_id: "north-beds")
    node = Node.new(node_id: "sensor-zone1-ch2", zone: zone)

    assert_equal "north-beds Node 3", node.display_name
  end

  test "malformed or out of range channel ids fall back safely to node id" do
    zone = create(:zone, name: "Tomatoes")

    assert_equal "sensor-zone1-ch4", Node.new(node_id: "sensor-zone1-ch4", zone: zone).display_name
    assert_equal "legacy-sensor", Node.new(node_id: "legacy-sensor", zone: zone).display_name
  end

  test "changing a custom name does not publish watering configuration" do
    node = Node.create!(valid_attrs.merge(name: nil))
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: ConfigPublishJob do
      node.update!(name: "Cherry Tomato")
    end
  end

  test "accepts nil config_status" do
    assert Node.new(valid_attrs.merge(config_status: nil)).valid?
  end

  test "accepts moisture calibration when both raw values are present" do
    node = Node.new(valid_attrs.merge(moisture_raw_dry: 552, moisture_raw_wet: 943))

    assert node.valid?
    assert node.calibration_configured?
  end

  test "rejects partial moisture calibration" do
    node = Node.new(valid_attrs.merge(moisture_raw_dry: 552, moisture_raw_wet: nil))

    assert_not node.valid?
    assert_includes node.errors[:base], "moisture calibration requires both dry and wet raw values"
  end

  test "rejects equal dry and wet moisture calibration values" do
    node = Node.new(valid_attrs.merge(moisture_raw_dry: 552, moisture_raw_wet: 552))

    assert_not node.valid?
    assert_includes node.errors[:base], "moisture calibration dry and wet raw values cannot be the same"
  end

  test "requires a zone" do
    node = Node.new(valid_attrs.merge(zone: nil))

    assert_not node.valid?
    assert_includes node.errors[:zone], "must exist"
  end

  test "database rejects a null zone id" do
    node = Node.new(valid_attrs.merge(node_id: "database-null-zone", zone: nil))

    assert_raises ActiveRecord::NotNullViolation do
      node.save!(validate: false)
    end
  end

  test "next expected wake is unknown when firmware schedule mode is not persisted" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    node = Node.create!(valid_attrs.merge(node_id: "wake-node", zone: zone))
    SensorReading.create!(
      zone: zone,
      node_id: node.node_id,
      recorded_at: Time.zone.parse("2026-06-23 08:00:00 UTC"),
      moisture_raw: 500
    )

    assert_nil node.next_expected_wake_at(reference_time: Time.zone.parse("2026-06-23 09:15:00 UTC"))
  end

  test "next expected wake is unknown without readings" do
    node = Node.create!(valid_attrs.merge(node_id: "wake-node-no-readings"))

    assert_nil node.next_expected_wake_at
  end

  test "assigned? returns true when zone is assigned" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))
    assert node.assigned?
  end

  test "enqueues config publish when zone assignment changes" do
    zone = create(:zone)
    node = Node.create!(valid_attrs)

    assert_enqueued_with(job: ConfigPublishJob) do
      node.update!(zone: zone)
    end
  end

  test "zone reassignment cannot split device_id siblings" do
    zone = create(:zone)
    other_zone = create(:zone)
    channels = 4.times.map do |channel|
      Node.create!(
        node_id: "sensor-zone1-ch#{channel}",
        device_id: "sensor-zone1",
        zone: other_zone,
        last_seen_at: Time.current
      )
    end

    moved = channels.fetch(2)
    assert_not moved.update(zone: zone)
    assert_includes moved.errors[:zone], "must match every channel in sensor package sensor-zone1"

    assert_equal [other_zone.id], channels.map { |node| node.reload.zone_id }.uniq
  end

  test "enqueues node config publish when assigned node calibration changes" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      node.update!(moisture_raw_dry: 552, moisture_raw_wet: 943)
    end
  end


  test "enqueues config publish when an assigned node is destroyed" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))

    assert_enqueued_with(job: ConfigPublishJob) do
      node.destroy!
    end
  end

  test "rejects deleting a canonical Node from a bound sensor package" do
    zone = create(:zone)
    SensorZoneProvisioner.call(zone: zone, sensor_device_id: "sensor-zone1")
    node = zone.nodes.find_by!(node_id: "sensor-zone1-ch2")

    error = assert_raises(ActiveRecord::RecordNotDestroyed) { node.destroy! }
    assert_match "cannot delete a Node from a bound sensor package", error.message
    assert_not node.destroyed?
    assert_equal 4, zone.reload.nodes.count
    assert Node.exists?(node.id)
  end

  test "rejects direct extra channel and package identity mutations in a bound package" do
    zone = create(:zone)
    SensorZoneProvisioner.call(zone: zone, sensor_device_id: "sensor-zone1")

    extra = Node.new(node_id: "sensor-zone1-ch4", device_id: "sensor-zone1", zone: zone, last_seen_at: nil)
    assert_not extra.save
    assert_includes extra.errors[:base], "canonical Nodes in a bound sensor package can only be changed by package provisioning"

    canonical = zone.nodes.find_by!(node_id: "sensor-zone1-ch0")
    assert_not canonical.update(device_id: "different-package")
    assert_includes canonical.errors[:base], "canonical Nodes in a bound sensor package can only be changed by package provisioning"
    assert_equal "sensor-zone1", canonical.reload.device_id
    assert_equal 4, zone.reload.nodes.count
  end

  test "rejects an invalid direct mutation before it can alter a bound package" do
    zone = create(:zone)
    SensorZoneProvisioner.call(zone: zone, sensor_device_id: "sensor-zone1")
    canonical = zone.nodes.find_by!(node_id: "sensor-zone1-ch0")

    assert_not canonical.update(node_id: "sensor-zone1-ch0\"")
    assert_includes canonical.errors[:node_id], "Node identity must use only ASCII letters, digits, hyphen, or underscore for firmware compatibility."
    assert_equal "sensor-zone1-ch0", canonical.reload.node_id
    assert zone.reload.canonical_sensor_package_nodes?
  end

  test "uses node crop profile and irrigation line for plant watering configuration" do
    plant_crop = create(:crop_profile, crop_id: "basil-node")
    zone = create(:zone)
    node = Node.create!(
      valid_attrs.merge(
        zone: zone,
        crop_profile: plant_crop,
        irrigation_line: 2
      )
    )

    assert_equal plant_crop, node.crop_profile
    assert node.watering_configured?
  end

  test "requires both an active Node and an active Zone for watering configuration" do
    crop = create(:crop_profile)
    inactive_zone = create(:zone, active: false)
    inactive_zone_node = Node.create!(valid_attrs.merge(node_id: "sensor-inactive-zone", zone: inactive_zone, crop_profile: crop, irrigation_line: 1, active: true))
    inactive_node = Node.create!(valid_attrs.merge(node_id: "sensor-inactive-node", zone: create(:zone), crop_profile: crop, irrigation_line: 2, active: false))

    assert_not inactive_zone_node.watering_configured?
    assert_not inactive_node.watering_configured?
  end

  test "crop-less node is not watering configured even when assigned to a zone" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))

    assert_nil node.crop_profile
    assert_not node.watering_configured?
  end

  test "allows nil irrigation lines for setup" do
    zone = create(:zone)
    Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch0", zone: zone, irrigation_line: nil))
    node = Node.new(valid_attrs.merge(node_id: "sensor-zone1-ch1", zone: zone, irrigation_line: nil))

    assert node.valid?
    assert_not node.watering_configured?
  end

  test "allows positive irrigation lines without a zone-size or installed-capacity maximum" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    zone = create(:zone)

    [1, 4, 5, 12].each do |line|
      node = Node.new(valid_attrs.merge(node_id: "sensor-zone1-line#{line}", zone: zone, irrigation_line: line))
      assert node.valid?, "expected line #{line} to be valid: #{node.errors.full_messages.join(', ')}"
    end
  end

  test "installed capacity support is separate from logical irrigation line validity" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch3", zone: zone, irrigation_line: 8))

    assert node.valid?
    assert_not node.irrigation_line_supported?

    ConnectionSetting.first.update!(irrigation_line_count: 8)
    assert node.reload.irrigation_line_supported?
  end

  test "capacity reduction disables but does not remap a logical irrigation line" do
    setting = ConnectionSetting.create!(irrigation_line_count: 8)
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch3", zone: zone, irrigation_line: 8))

    assert node.irrigation_line_supported?
    setting.update!(irrigation_line_count: 4)

    assert_equal 8, node.reload.irrigation_line
    assert_not node.irrigation_line_supported?
  end

  test "line one above installed capacity is unsupported" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch4", zone: zone, irrigation_line: 5))

    assert_not node.irrigation_line_supported?
  end

  test "rejects zero and negative irrigation lines" do
    [0, -1].each do |line|
      node = Node.new(valid_attrs.merge(irrigation_line: line))

      assert_not node.valid?
      assert_includes node.errors[:irrigation_line], "must be greater than 0"
    end
  end

  test "rejects duplicate irrigation lines in the same zone" do
    zone = create(:zone)
    Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch0", zone: zone, irrigation_line: 1))
    node = Node.new(valid_attrs.merge(node_id: "sensor-zone1-ch1", zone: zone, irrigation_line: 1))

    assert_not node.valid?
    assert_includes node.errors[:irrigation_line], "has already been taken"
  end

  test "rejects duplicate irrigation lines in different zones" do
    zone1 = create(:zone)
    zone2 = create(:zone)
    Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch0", zone: zone1, irrigation_line: 5))
    node = Node.new(valid_attrs.merge(node_id: "sensor-zone2-ch0", zone: zone2, irrigation_line: 5))

    assert_not node.valid?
    assert_includes node.errors[:irrigation_line], "has already been taken"
  end

  test "allows different irrigation lines in different zones" do
    zone1 = create(:zone)
    zone2 = create(:zone)
    Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch0", zone: zone1, irrigation_line: 4))
    node = Node.new(valid_attrs.merge(node_id: "sensor-zone2-ch0", zone: zone2, irrigation_line: 5))

    assert node.valid?
  end

  test "allows reassignment to an unused greenhouse-wide irrigation line" do
    node = Node.create!(valid_attrs.merge(irrigation_line: 3))

    assert node.update(irrigation_line: 11)
    assert_equal 11, node.reload.irrigation_line
  end

  test "database unique index rejects duplicate non-null irrigation lines across zones" do
    zone1 = create(:zone)
    zone2 = create(:zone)
    Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch0", zone: zone1, irrigation_line: 5))
    duplicate = Node.new(valid_attrs.merge(node_id: "sensor-zone2-ch0", zone: zone2, irrigation_line: 5))

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "database allows multiple null irrigation lines" do
    Node.create!(valid_attrs.merge(node_id: "sensor-zone1-ch0", irrigation_line: nil))
    node = Node.new(valid_attrs.merge(node_id: "sensor-zone2-ch0", irrigation_line: nil))

    node.save!(validate: false)
    assert node.persisted?
  end

  test "database check rejects zero and negative irrigation lines" do
    [0, -1].each do |line|
      node = Node.new(valid_attrs.merge(node_id: "sensor-zone1-line#{line}", irrigation_line: line))

      assert_raises ActiveRecord::StatementInvalid do
        node.save!(validate: false)
      end
    end
  end

  test "enqueues config publish when a zone-owned node is destroyed" do
    node = Node.create!(valid_attrs)

    assert_enqueued_with(job: ConfigPublishJob) do
      node.destroy!
    end
  end

  test "offline? is false when last seen within the expected interval" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    node = Node.create!(valid_attrs.merge(zone: zone, last_seen_at: 10.minutes.ago))

    assert_not node.offline?
  end

  test "offline? treats a never-seen node as offline without raising" do
    node = Node.create!(valid_attrs.merge(last_seen_at: nil))

    assert node.offline?
  end

  test "offline? is false when stale but within twice the expected interval" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    node = Node.create!(valid_attrs.merge(zone: zone, last_seen_at: 90.minutes.ago))

    assert_not node.offline?
  end

  test "offline? is true when last seen beyond twice the expected interval" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    node = Node.create!(valid_attrs.merge(zone: zone, last_seen_at: 3.hours.ago))

    assert node.offline?
  end
end
