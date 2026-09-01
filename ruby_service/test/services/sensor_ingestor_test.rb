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

  test "ingests canonical node fixture for an assigned node without enqueuing watering command" do
    Node.create!(
      node_id: "pico-w-zone1",
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
    node = Node.find_by!(node_id: "pico-w-zone1")
    assert_equal @zone, reading.zone
    assert_equal "node-state/v1", reading.schema_version
    assert_equal(-54, reading.wifi_rssi)
    assert_equal "node-state/v1", reading.raw_payload["schema_version"]
    assert_equal "pico-w-zone1", reading.raw_payload["node_id"]
    assert_equal "zone1", reading.raw_payload["zone_id"]
    assert_equal 354, reading.raw_payload["moisture_raw"]
    assert_equal reading.recorded_at.iso8601(3), reading.raw_payload["recorded_at"]

    assert_equal @zone, node.zone
    assert_equal "zone1", node.reported_zone_id
    assert_equal "degraded", node.health
    assert_equal reading.recorded_at, reading.raw_payload["recorded_at"]
    assert_equal 0, WateringEvent.count
  end

  test "preserves command correlation id in raw payload" do
    Node.create!(
      node_id: "pico-w-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )
    payload = load_fixture("node-state-v1.json").merge(
      "publish_reason" => "request_reading",
      "command_message_id" => "pi-001",
      "lora_sequence" => 42
    )

    SensorIngestor.new(payload).call

    reading = SensorReading.order(:created_at).last
    assert_equal "request_reading", reading.publish_reason
    assert_equal "pi-001", reading.raw_payload["command_message_id"]
    assert_equal 42, reading.raw_payload["lora_sequence"]
  end

  test "marks matching request reading command acknowledged from correlated result" do
    Node.create!(
      node_id: "pico-w-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )
    command = NodeCommand.create!(
      zone: @zone,
      node_id: "pico-w-zone1",
      command: "request_reading",
      command_id: "pi-001",
      status: "command_sent",
      issued_at: Time.current
    )
    payload = load_fixture("node-state-v1.json").merge(
      "publish_reason" => "request_reading",
      "command_message_id" => "pi-001"
    )

    SensorIngestor.new(payload).call

    assert_equal "acknowledged", command.reload.status
    assert command.acknowledged_at.present?
  end

  test "does not reopen a timed out command from a delayed correlated result" do
    Node.create!(
      node_id: "pico-w-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )
    command = NodeCommand.create!(
      zone: @zone,
      node_id: "pico-w-zone1",
      command: "request_reading",
      command_id: "pi-late",
      status: "timeout",
      issued_at: Time.current
    )
    payload = load_fixture("node-state-v1.json").merge(
      "publish_reason" => "request_reading",
      "command_message_id" => "pi-late"
    )

    SensorIngestor.new(payload).call

    assert_equal "timeout", command.reload.status
  end

  test "ingests partial payload for an assigned node without making watering decision" do
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

  test "updates an unassigned node but skips persistence and decisions" do
    payload = load_fixture("node-state-v1.json").merge("node_id" => "unassigned-zone1")

    assert_no_enqueued_jobs only: CommandPublishJob do
      SensorIngestor.new(payload).call
    end

    node = Node.find_by!(node_id: "unassigned-zone1")

    assert_nil node.zone
    assert_equal "zone1", node.reported_zone_id
    assert_equal "degraded", node.health
    assert_equal 0, SensorReading.where(node_id: "unassigned-zone1").count
    assert_equal 0, WateringEvent.count
  end

  test "stores the physical device id from channel state" do
    payload = load_fixture("node-state-v1.json").merge(
      "node_id" => "sensor-zone1-ch2",
      "device_id" => "sensor-zone1"
    )

    SensorIngestor.new(payload).call

    assert_equal "sensor-zone1", Node.find_by!(node_id: "sensor-zone1-ch2").device_id
  end

  test "enqueues node config refresh when desired timezone offset is stale" do
    node = Node.create!(
      node_id: "pico-w-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      desired_config: { "utc_offset_hours" => PublishNodeConfigJob.current_utc_offset_hours - 1 }
    )
    payload = load_fixture("node-state-v1.json").merge(
      "timestamp" => Time.current.utc.iso8601
    )

    assert_enqueued_with(job: PublishNodeConfigJob, args: [node.id]) do
      SensorIngestor.new(payload).call
    end
  end

  test "does not enqueue node config refresh when desired timezone offset is current" do
    Node.create!(
      node_id: "pico-w-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      desired_config: { "utc_offset_hours" => PublishNodeConfigJob.current_utc_offset_hours }
    )
    payload = load_fixture("node-state-v1.json").merge(
      "timestamp" => Time.current.utc.iso8601
    )

    assert_no_enqueued_jobs only: PublishNodeConfigJob do
      SensorIngestor.new(payload).call
    end
  end

  test "persists a temperature-only reading without soil moisture" do
    Node.create!(node_id: "pico-w-zone1", zone: @zone, last_seen_at: 1.hour.ago)
    payload = load_fixture("node-state-v1.json").except("moisture_raw", "moisture_percent").merge(
      "timestamp" => Time.current.utc.iso8601,
      "air_temperature_c" => 25.0,
      "humidity_percent" => 62.5,
      "soil_moisture_read" => false
    )

    reading = SensorIngestor.new(payload).call

    assert_nil reading.moisture_raw
    assert_equal 25.0, reading.air_temperature_c.to_f
    assert_equal 62.5, reading.humidity_percent.to_f
    assert_not reading.soil_moisture_read
    assert_equal "normal", reading.greenhouse_alert_status
  end

  test "ignores duplicate node state for the same node and timestamp" do
    Node.create!(
      node_id: "pico-w-zone1",
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

    assert_equal 1, SensorReading.where(node_id: "pico-w-zone1", recorded_at: SensorReading.order(:created_at).last.recorded_at).count
    assert_equal 0, WateringEvent.count
  end

  test "persists a stale reading but does not make an automatic decision" do
    Node.create!(
      node_id: "pico-w-zone1",
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
    node = Node.find_by!(node_id: "pico-w-zone1")

    assert_equal stale_time.to_i, reading.recorded_at.to_i
    assert_equal 0, WateringEvent.count
    assert node.last_seen_at > reading.recorded_at
  end

  test "uses DB-assigned zone even when node reports a different zone_id in payload" do
    other_zone = create(:zone, zone_id: "zone2", name: "Zone 2")
    Node.create!(
      node_id: "pico-w-zone1",
      zone: @zone,
      last_seen_at: 1.hour.ago,
      config_status: "applied"
    )

    payload = load_fixture("node-state-v1.json").merge(
      "node_id" => "pico-w-zone1",
      "zone_id" => other_zone.zone_id,
      "timestamp" => Time.current.utc.iso8601
    )

    SensorIngestor.new(payload).call

    reading = SensorReading.order(:created_at).last
    assert_equal @zone, reading.zone, "reading should be filed under the DB-assigned zone, not the payload zone_id"
    assert_equal other_zone.zone_id, Node.find_by!(node_id: "pico-w-zone1").reported_zone_id
  end

  test "does not move node last_seen_at backwards when an older reading arrives" do
    recent_seen_at = 2.minutes.ago.utc
    Node.create!(
      node_id: "pico-w-zone1",
      zone: @zone,
      last_seen_at: recent_seen_at,
      config_status: "applied"
    )

    payload = load_fixture("node-state-v1.json").merge("timestamp" => 15.minutes.ago.utc.iso8601)

    SensorIngestor.new(payload).call

    assert_equal recent_seen_at.to_i, Node.find_by!(node_id: "pico-w-zone1").last_seen_at.to_i
  end

  test "rejects payloads that fail node state contract validation" do
    Node.create!(
      node_id: "pico-w-zone1",
      zone: @zone,
      last_seen_at: Time.current,
      config_status: "applied"
    )

    payload = load_fixture("node-state-v1.json").merge(
      "timestamp" => Time.current.utc.iso8601,
      "unexpected" => "nope"
    )

    error = assert_raises(ArgumentError) do
      SensorIngestor.new(payload).call
    end

    assert_match "unknown keys", error.message
    assert_equal 0, SensorReading.count
    assert_equal 0, WateringEvent.count
  end
end
