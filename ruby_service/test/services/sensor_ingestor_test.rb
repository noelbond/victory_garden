require "test_helper"

class SensorIngestorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def load_fixture(name)
    JSON.parse(File.read(Rails.root.join("..", "contracts", "examples", name)))
  end

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    @crop = create(:crop_profile, crop_id: "tomato-test")
    @zone = create(:zone, zone_id: "zone1", name: "Zone 1", crop_profile: @crop)
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "ingests canonical node fixture for a claimed node without enqueuing watering command" do
    Node.create!(
      node_id: "mkr1010-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )

    freeze_time do
      payload = load_fixture("node-state-v1.json").merge("timestamp" => Time.current.utc.iso8601)

      assert_no_enqueued_jobs only: CommandPublishJob do
        SensorIngestor.new(payload).call
      end
    end

    reading = SensorReading.order(:created_at).last
    node = Node.find_by!(node_id: "mkr1010-zone1")
    assert_equal @zone, reading.zone
    assert_equal "node-state/v1", reading.schema_version
    assert_equal(-54, reading.wifi_rssi)
    assert_equal "node-state/v1", reading.raw_payload["schema_version"]
    assert_equal "mkr1010-zone1", reading.raw_payload["node_id"]
    assert_equal "zone1", reading.raw_payload["zone_id"]
    assert_equal 354, reading.raw_payload["moisture_raw"]
    assert_equal reading.recorded_at.iso8601(3), reading.raw_payload["recorded_at"]

    assert_equal @zone, node.zone
    assert_equal "zone1", node.reported_zone_id
    assert_equal "degraded", node.health
    assert_equal reading.recorded_at, reading.raw_payload["recorded_at"]
    assert_equal 0, WateringEvent.count
  end

  test "ingests partial payload for a claimed node without making watering decision" do
    Node.create!(
      node_id: "partial-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )

    payload = load_fixture("node-state-partial.json")

    assert_no_enqueued_jobs only: CommandPublishJob do
      SensorIngestor.new(payload).call
    end

    reading = SensorReading.order(:created_at).last

    assert_equal @zone, reading.zone
    assert_nil reading.moisture_percent
    assert_equal 0, WateringEvent.count
  end

  test "updates an unclaimed node but skips persistence and decisions" do
    payload = load_fixture("node-state-v1.json").merge("node_id" => "unclaimed-zone1")

    assert_no_enqueued_jobs only: CommandPublishJob do
      SensorIngestor.new(payload).call
    end

    node = Node.find_by!(node_id: "unclaimed-zone1")

    assert_nil node.zone
    assert_equal "zone1", node.reported_zone_id
    assert_equal "degraded", node.health
    assert_equal 0, SensorReading.where(node_id: "unclaimed-zone1").count
    assert_equal 0, WateringEvent.count
  end

  test "ignores duplicate node state for the same node and timestamp" do
    Node.create!(
      node_id: "mkr1010-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )

    freeze_time do
      payload = load_fixture("node-state-v1.json").merge("timestamp" => Time.current.utc.iso8601)

      assert_no_enqueued_jobs only: CommandPublishJob do
        SensorIngestor.new(payload).call
        SensorIngestor.new(payload).call
      end
    end

    assert_equal 1, SensorReading.where(node_id: "mkr1010-zone1", recorded_at: SensorReading.order(:created_at).last.recorded_at).count
    assert_equal 0, WateringEvent.count
  end

  test "persists a stale reading but does not make an automatic decision" do
    Node.create!(
      node_id: "mkr1010-zone1",
      zone: @zone,
      last_seen_at: Time.current,
      config_status: "applied"
    )

    stale_time = 20.minutes.ago.utc
    payload = load_fixture("node-state-v1.json").merge("timestamp" => stale_time.iso8601)

    assert_no_enqueued_jobs only: CommandPublishJob do
      SensorIngestor.new(payload).call
    end

    reading = SensorReading.order(:created_at).last
    node = Node.find_by!(node_id: "mkr1010-zone1")

    assert_equal stale_time.to_i, reading.recorded_at.to_i
    assert_equal 0, WateringEvent.count
    assert node.last_seen_at > reading.recorded_at
  end

  test "uses DB-assigned zone even when node reports a different zone_id in payload" do
    other_zone = create(:zone, zone_id: "zone2", name: "Zone 2")
    Node.create!(
      node_id: "mkr1010-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )

    payload = load_fixture("node-state-v1.json").merge(
      "node_id" => "mkr1010-zone1",
      "zone_id" => other_zone.zone_id,
      "timestamp" => Time.current.utc.iso8601
    )

    SensorIngestor.new(payload).call

    reading = SensorReading.order(:created_at).last
    assert_equal @zone, reading.zone, "reading should be filed under the DB-assigned zone, not the payload zone_id"
    assert_equal other_zone.zone_id, Node.find_by!(node_id: "mkr1010-zone1").reported_zone_id
  end

  test "does not move node last_seen_at backwards when an older reading arrives" do
    recent_seen_at = 2.minutes.ago.utc
    Node.create!(
      node_id: "mkr1010-zone1",
      zone: @zone,
      last_seen_at: recent_seen_at,
      config_status: "applied"
    )

    payload = load_fixture("node-state-v1.json").merge("timestamp" => 15.minutes.ago.utc.iso8601)

    SensorIngestor.new(payload).call

    assert_equal recent_seen_at.to_i, Node.find_by!(node_id: "mkr1010-zone1").last_seen_at.to_i
  end
end
