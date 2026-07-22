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

  test "requires last_seen_at" do
    node = Node.new(valid_attrs.merge(last_seen_at: nil))
    assert_not node.valid?
    assert_includes node.errors[:last_seen_at], "can't be blank"
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

  test "display name falls back to stable node id" do
    node = Node.new(valid_attrs)

    assert_equal "pico-w-test-001", node.display_name
  end

  test "sync_default_names_for_zone names device channels from zone label" do
    zone = create(:zone, name: "Greenhouse Zone 1")
    channels = 4.times.map do |channel|
      Node.create!(
        node_id: "sensor-zone1-ch#{channel}",
        device_id: "sensor-zone1",
        zone: zone,
        last_seen_at: Time.current
      )
    end

    Node.sync_default_names_for_zone!(zone)

    assert_equal(
      ["Greenhouse Zone 1_Ch1", "Greenhouse Zone 1_Ch2", "Greenhouse Zone 1_Ch3", "Greenhouse Zone 1_Ch4"],
      channels.map { |node| node.reload.name }
    )
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

  test "unassigned scope returns nodes without a zone" do
    zone = create(:zone)
    assigned = Node.create!(valid_attrs.merge(node_id: "assigned-node", zone: zone))
    unassigned = Node.create!(valid_attrs.merge(node_id: "unassigned-node"))

    assert_includes Node.unassigned, unassigned
    assert_not_includes Node.unassigned, assigned
  end

  test "assigned scope returns nodes with a zone" do
    zone = create(:zone)
    assigned = Node.create!(valid_attrs.merge(node_id: "assigned-node", zone: zone))
    unassigned = Node.create!(valid_attrs.merge(node_id: "unassigned-node"))

    assert_includes Node.assigned, assigned
    assert_not_includes Node.assigned, unassigned
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

  test "assigned? returns false when no zone is assigned" do
    node = Node.create!(valid_attrs)
    assert_not node.assigned?
  end

  test "enqueues config publish when zone assignment changes" do
    zone = create(:zone)
    node = Node.create!(valid_attrs)

    assert_enqueued_with(job: ConfigPublishJob) do
      node.update!(zone: zone)
    end
  end

  test "zone assignment cascades to physical device siblings" do
    zone = create(:zone)
    channels = 4.times.map do |channel|
      Node.create!(
        node_id: "sensor-zone1-ch#{channel}",
        device_id: "sensor-zone1",
        last_seen_at: Time.current
      )
    end

    channels.fetch(2).update!(zone: zone)

    assert_equal [zone.id], Node.where(device_id: "sensor-zone1").distinct.pluck(:zone_id)
  end

  test "enqueues node config publish when assigned node calibration changes" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      node.update!(moisture_raw_dry: 552, moisture_raw_wet: 943)
    end
  end

  test "does not enqueue node config publish when unassigned node calibration changes" do
    node = Node.create!(valid_attrs)

    assert_no_enqueued_jobs only: PublishNodeConfigJob do
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

  test "uses node crop profile and irrigation line for plant watering configuration" do
    fallback_crop = create(:crop_profile, crop_id: "tomato-node-fallback")
    plant_crop = create(:crop_profile, crop_id: "basil-node")
    zone = create(:zone, crop_profile: fallback_crop)
    node = Node.create!(
      valid_attrs.merge(
        zone: zone,
        crop_profile: plant_crop,
        irrigation_line: 2
      )
    )

    assert_equal plant_crop, node.effective_crop_profile
    assert node.watering_configured?
  end

  test "falls back to zone crop profile until a plant crop is chosen" do
    zone = create(:zone)
    node = Node.create!(valid_attrs.merge(zone: zone))

    assert_equal zone.crop_profile, node.effective_crop_profile
    assert_not node.watering_configured?
  end

  test "rejects node irrigation line above configured pump output count" do
    ConnectionSetting.create!(irrigation_line_count: 2)
    node = Node.new(valid_attrs.merge(irrigation_line: 3))

    assert_not node.valid?
    assert_includes node.errors[:irrigation_line], "must be between 1 and 2"
  end

  test "does not enqueue config publish when an unassigned node is destroyed" do
    node = Node.create!(valid_attrs)

    assert_no_enqueued_jobs only: ConfigPublishJob do
      node.destroy!
    end
  end
end
