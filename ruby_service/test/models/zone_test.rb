require "test_helper"

class ZoneTest < ActiveSupport::TestCase
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

  test "rejects out of range allowed hours" do
    zone = build(:zone, allowed_hours: { "start_hour" => 24, "end_hour" => 8 })

    assert_not zone.valid?
    assert_includes zone.errors[:allowed_hours], "start_hour must be an integer between 0 and 23"
  end

  test "rejects partial allowed hours" do
    zone = build(:zone, allowed_hours: { "start_hour" => 6 })

    assert_not zone.valid?
    assert_includes zone.errors[:allowed_hours], "must include start_hour and end_hour"
  end

  test "rejects zero width allowed hours window" do
    zone = build(:zone, allowed_hours: { "start_hour" => 12, "end_hour" => 12 })

    assert_not zone.valid?
    assert_includes zone.errors[:allowed_hours], "start_hour and end_hour cannot be the same"
  end

  test "enqueues config publish when zone policy changes" do
    zone = create(:zone, allowed_hours: { "start_hour" => 6, "end_hour" => 20 })

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(allowed_hours: { "start_hour" => 7, "end_hour" => 19 })
    end
  end

  test "meaningful zone policy changes still enqueue config publication" do
    zone = create(:zone, active: true)

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(active: false)
    end
  end

  test "defaults allowed hours and reading frequency" do
    zone = create(:zone)

    assert_equal({ "start_hour" => 6, "end_hour" => 20 }, zone.allowed_hours)
    assert_equal 3_600_000, zone.publish_interval_ms
  end

  test "allows a zone without a sensor device binding" do
    zone = create(:zone, sensor_device_id: nil)

    assert_nil zone.sensor_device_id
  end

  test "enforces the exact firmware identity contract for direct Zone mutations" do
    zone = create(:zone, zone_id: "zone-safe")

    assert_not zone.update(zone_id: "zone\"unsafe")
    assert_includes zone.errors[:zone_id], "Zone identity must use only ASCII letters, digits, hyphen, or underscore for firmware compatibility."
    assert_equal "zone-safe", zone.reload.zone_id

    assert_not zone.update(zone_id: "z" * 32)
    assert_includes zone.errors[:zone_id], "Zone identity must be at most 31 bytes for firmware compatibility."
    assert_equal "zone-safe", zone.reload.zone_id
  end

  test "accepts maximum-length firmware-safe Zone identities unchanged" do
    zone_id = "Z" * SensorIdentityContract::MAX_FIRMWARE_ID_BYTES
    zone = create(:zone, zone_id: zone_id)

    assert_equal zone_id, zone.reload.zone_id
  end

  test "rejects unsafe and overlong direct sensor package binding mutations" do
    zone = create(:zone)

    assert_not zone.update(sensor_device_id: "package\"unsafe")
    assert_includes zone.errors[:sensor_device_id], "Sensor package identity must use only ASCII letters, digits, hyphen, or underscore for firmware compatibility."
    assert_nil zone.reload.sensor_device_id

    assert_not zone.update(sensor_device_id: "p" * (SensorIdentityContract::MAX_PACKAGE_ID_BYTES + 1))
    assert_includes zone.errors[:sensor_device_id], "Sensor package identity must be at most 27 bytes for firmware compatibility."
    assert_nil zone.reload.sensor_device_id
  end

  test "rejects whitespace in direct firmware-visible Zone identities without normalizing it" do
    zone = create(:zone, zone_id: "zone-safe")

    [" zone-safe", "zone-safe ", "\tzone-safe", "zone-safe\n"].each do |unsafe_id|
      assert_not zone.update(zone_id: unsafe_id)
      assert_includes zone.errors[:zone_id], "Zone identity must use only ASCII letters, digits, hyphen, or underscore for firmware compatibility."
      assert_equal "zone-safe", zone.reload.zone_id
    end
  end

  test "rejects a blank direct Zone identity mutation instead of generating a replacement" do
    zone = create(:zone, zone_id: "zone-safe")

    assert_not zone.update(zone_id: "")
    assert_includes zone.errors[:zone_id], "can't be blank"
    assert_equal "zone-safe", zone.reload.zone_id
  end

  test "generates a Zone identity only when it is absent, not when invalid input is supplied" do
    generated = Zone.new
    assert generated.valid?
    assert_match(/\Azone-[A-Fa-f0-9]{6}\z/, generated.zone_id)

    explicit_blank = Zone.new(zone_id: "")
    assert_not explicit_blank.valid?
    assert_includes explicit_blank.errors[:zone_id], "can't be blank"

    explicit_whitespace = Zone.new(zone_id: "\tzone")
    assert_not explicit_whitespace.valid?
    assert_includes explicit_whitespace.errors[:zone_id], "Zone identity must use only ASCII letters, digits, hyphen, or underscore for firmware compatibility."
  end

  test "rejects direct sensor device binding without the canonical package Nodes" do
    zone = create(:zone)

    assert_not zone.update(sensor_device_id: "sensor-package-1")
    assert_includes zone.errors[:sensor_device_id], "must be established by sensor package provisioning or assignment"
    assert_nil zone.reload.sensor_device_id
  end

  test "rejects duplicate non-null sensor device bindings" do
    bound_zone = create(:zone)
    SensorZoneProvisioner.call(zone: bound_zone, sensor_device_id: "sensor-package-1")
    duplicate = build(:zone, sensor_device_id: "sensor-package-1")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:sensor_device_id], "has already been taken"
  end

  test "allows multiple zones without sensor device bindings" do
    create(:zone, sensor_device_id: nil)
    zone = build(:zone, sensor_device_id: nil)

    assert zone.valid?
  end

  test "database unique index rejects duplicate sensor device bindings" do
    bound_zone = create(:zone)
    SensorZoneProvisioner.call(zone: bound_zone, sensor_device_id: "sensor-package-1")
    duplicate = build(:zone, sensor_device_id: "sensor-package-1")

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "rejects direct sensor device binding changes while preserving package Node state" do
    crop = create(:crop_profile)
    zone = create(:zone)
    SensorZoneProvisioner.call(zone: zone, sensor_device_id: "sensor-package-old")
    node = zone.nodes.find_by!(node_id: "sensor-package-old-ch0")
    node.update!(crop_profile: crop, irrigation_line: 8, last_seen_at: Time.current)
    SensorReading.create!(zone: zone, node_id: node.node_id, recorded_at: Time.current, moisture_raw: 500)

    assert_not zone.update(sensor_device_id: "sensor-package-new")

    assert_equal zone.zone_id, zone.reload.zone_id
    assert_equal "sensor-package-old", zone.sensor_device_id
    assert_equal "sensor-package-old-ch0", node.reload.node_id
    assert_equal crop, node.crop_profile
    assert_equal 8, node.irrigation_line
    assert_equal 1, SensorReading.where(node_id: node.node_id).count
  end

  test "cannot destroy a zone while it owns nodes" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1-ch0", zone: zone, last_seen_at: nil)

    assert_not zone.destroy
    assert_includes zone.errors[:base], "Cannot delete record because dependent nodes exist"
    assert_equal zone, node.reload.zone
  end

  test "enqueues config publish when reading frequency changes" do
    zone = create(:zone)

    assert_enqueued_with(job: ConfigPublishJob) do
      zone.update!(publish_interval_ms: 300_000)
    end
  end

  test "reading_frequency_hours converts ms to hours" do
    zone = create(:zone, publish_interval_ms: 3_600_000)
    assert_equal 1, zone.reading_frequency_hours

    zone.update!(publish_interval_ms: 7_200_000)
    assert_equal 2, zone.reading_frequency_hours
  end

  test "renaming zone changes derived channel display names without storing names" do
    zone = create(:zone, name: "Original Zone")
    channel = Node.create!(
      node_id: "sensor-zone1-ch0",
      device_id: "sensor-zone1",
      zone: zone,
      last_seen_at: Time.current
    )

    zone.update!(name: "Greenhouse Zone 1")

    assert_equal "Greenhouse Zone 1 Node 1", channel.reload.display_name
    assert_nil channel.name
    assert_equal "sensor-zone1-ch0", channel.node_id
  end

  test "renaming zone preserves a custom node name" do
    zone = create(:zone, name: "Original Zone")
    channel = Node.create!(node_id: "sensor-zone1-ch0", zone: zone, name: "Cherry Tomato", last_seen_at: Time.current)

    zone.update!(name: "Greenhouse Zone 1")

    assert_equal "Cherry Tomato", channel.reload.name
    assert_equal "Cherry Tomato", channel.display_name
    assert_equal "sensor-zone1-ch0", channel.node_id
  end

  test "renaming zone does not guess at or rewrite a legacy stored generated name" do
    zone = create(:zone, name: "Original Zone")
    channel = Node.create!(node_id: "sensor-zone1-ch0", zone: zone, name: "Original Zone_Ch1", last_seen_at: Time.current)

    zone.update!(name: "Greenhouse Zone 1")

    assert_equal "Original Zone_Ch1", channel.reload.name
    assert_equal "Original Zone_Ch1", channel.display_name
  end

  test "publish_interval_ms rejects zero" do
    zone = build(:zone, publish_interval_ms: 0)
    assert_not zone.valid?
    assert_includes zone.errors[:publish_interval_ms], "must be greater than 0"
  end

  test "publish_interval_ms rejects negative values" do
    zone = build(:zone, publish_interval_ms: -1)
    assert_not zone.valid?
    assert_includes zone.errors[:publish_interval_ms], "must be greater than 0"
  end

  test "publish_interval_ms rejects non-integer values" do
    zone = build(:zone, publish_interval_ms: 3600.5)
    assert_not zone.valid?
    assert_includes zone.errors[:publish_interval_ms], "must be an integer"
  end

  test "enqueues one node config publish per device when zone policy changes" do
    zone = create(:zone, allowed_hours: { "start_hour" => 6, "end_hour" => 20 })
    channels = 4.times.map do |channel|
      Node.create!(node_id: "sensor-zone1-ch#{channel}", device_id: "sensor-zone1", zone: zone, last_seen_at: Time.current)
    end

    assert_enqueued_jobs 1, only: PublishNodeConfigJob do
      zone.update!(allowed_hours: { "start_hour" => 7, "end_hour" => 19 })
    end
    enqueued_job = enqueued_jobs.find { |job| job[:job] == PublishNodeConfigJob }
    assert_includes channels.map(&:id), enqueued_job[:args].first
  end

end
