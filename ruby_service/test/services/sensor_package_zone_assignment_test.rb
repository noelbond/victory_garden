require "test_helper"

class SensorPackageZoneAssignmentTest < ActiveSupport::TestCase
  def create_package(zone:, device_id: "sensor-package-1", crop: nil, line_offset: 0)
    4.times.map do |channel|
      Node.create!(
        node_id: "#{device_id}-ch#{channel}",
        device_id: device_id,
        zone: zone,
        crop_profile: crop,
        irrigation_line: line_offset + channel + 1,
        name: channel.zero? ? "Custom Node" : nil,
        moisture_raw_dry: 400 + channel,
        moisture_raw_wet: 800 + channel,
        last_seen_at: Time.current
      )
    end
  end

  def create_bound_package(zone:, device_id: "sensor-package-1", crop: nil, line_offset: 0)
    channels = create_package(zone: zone, device_id: device_id, crop: crop, line_offset: line_offset)
    SensorPackageZoneAssignment.call(node: channels.first, zone: zone)
    channels
  end

  test "binds an already co-located package to its Zone without changing Node state" do
    zone = create(:zone, sensor_device_id: nil)
    crop = create(:crop_profile)
    channels = create_package(zone: zone, crop: crop)
    SensorReading.create!(zone: zone, node_id: channels.first.node_id, recorded_at: Time.current, moisture_raw: 500)
    before = channels.map { |node| node.reload.attributes.slice("node_id", "zone_id", "crop_profile_id", "irrigation_line", "name", "moisture_raw_dry", "moisture_raw_wet") }

    assigned = SensorPackageZoneAssignment.call(node: channels.second, zone: zone)

    assert_equal channels.second.id, assigned.id
    assert_equal "sensor-package-1", zone.reload.sensor_device_id
    assert_equal before, channels.map { |node| node.reload.attributes.slice("node_id", "zone_id", "crop_profile_id", "irrigation_line", "name", "moisture_raw_dry", "moisture_raw_wet") }
    assert_equal 1, SensorReading.where(node_id: channels.first.node_id).count
  end

  test "rejects moving one package channel to another Zone without changing siblings" do
    source_zone = create(:zone)
    target_zone = create(:zone)
    channels = create_bound_package(zone: source_zone)

    error = assert_raises(SensorPackageZoneAssignment::AssignmentError) do
      SensorPackageZoneAssignment.call(node: channels.second, zone: target_zone)
    end

    assert_match "individual channel reassignment is not allowed", error.message
    assert_equal [source_zone.id], channels.map { |node| node.reload.zone_id }.uniq
    assert_nil target_zone.reload.sensor_device_id
  end

  test "rejects a target Zone already bound to another package" do
    source_zone = create(:zone)
    target_zone = create(:zone)
    channels = create_bound_package(zone: source_zone)
    create_bound_package(zone: target_zone, device_id: "sensor-package-2", line_offset: 4)

    error = assert_raises(SensorPackageZoneAssignment::AssignmentError) do
      SensorPackageZoneAssignment.call(node: channels.first, zone: target_zone)
    end

    assert_match "already bound to sensor package sensor-package-2", error.message
    assert_equal [source_zone.id], channels.map { |node| node.reload.zone_id }.uniq
  end

  test "model validation rejects a direct split-package update" do
    source_zone = create(:zone)
    target_zone = create(:zone)
    channels = create_bound_package(zone: source_zone)

    assert_not channels.first.update(zone: target_zone)
    assert_includes channels.first.errors[:zone], "must match every channel in sensor package sensor-package-1"
    assert_equal [source_zone.id], channels.map { |node| node.reload.zone_id }.uniq
  end

  test "rejects binding an incomplete package" do
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-package-1-ch0", device_id: "sensor-package-1", zone: zone, last_seen_at: nil)

    error = assert_raises(SensorPackageZoneAssignment::AssignmentError) do
      SensorPackageZoneAssignment.call(node: node, zone: zone)
    end

    assert_match "exactly its canonical four channels", error.message
    assert_nil zone.reload.sensor_device_id
  end
end
