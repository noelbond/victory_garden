require "test_helper"

class SensorIngestorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def load_fixture(name)
    JSON.parse(File.read(Rails.root.join("..", "contracts", "examples", name)))
  end

  setup do
    ActiveJob::Base.queue_adapter = :test

    @crop = create(:crop_profile, crop_id: "tomato-test")
    @zone = create(:zone, zone_id: "zone1", name: "Zone 1", crop_profile: @crop)
  end

  test "ingests canonical node fixture and enqueues watering command" do
    payload = load_fixture("node-state-v1.json")

    assert_enqueued_jobs 1, only: CommandPublishJob do
      SensorIngestor.new(payload).call
    end

    reading = SensorReading.order(:created_at).last
    node = Node.find_by!(node_id: "mkr1010-zone1")
    event = WateringEvent.order(:created_at).last

    assert_equal @zone, reading.zone
    assert_equal "node-state/v1", reading.schema_version
    assert_equal(-54, reading.wifi_rssi)
    assert_equal "node-state/v1", reading.raw_payload["schema_version"]
    assert_equal "mkr1010-zone1", reading.raw_payload["node_id"]
    assert_equal "zone1", reading.raw_payload["zone_id"]
    assert_equal 354, reading.raw_payload["moisture_raw"]
    assert_equal "2026-03-18T23:13:56.000Z", reading.raw_payload["recorded_at"]

    assert_nil node.zone
    assert_equal "zone1", node.reported_zone_id
    assert_equal "degraded", node.health

    assert_equal "start_watering", event.command
    assert_equal 45, event.runtime_seconds
  end

  test "ingests partial payload without making watering decision" do
    payload = load_fixture("node-state-partial.json")

    assert_no_enqueued_jobs only: CommandPublishJob do
      SensorIngestor.new(payload).call
    end

    reading = SensorReading.order(:created_at).last

    assert_equal @zone, reading.zone
    assert_nil reading.moisture_percent
    assert_equal 0, WateringEvent.count
  end
end
