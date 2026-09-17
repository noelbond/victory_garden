require "test_helper"

class WateringCommandTest < ActiveSupport::TestCase
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

  test "start rejects a zone-only manual watering command" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1")

    error = assert_raises(ArgumentError) { WateringCommand.start(zone) }
    assert_equal "start_watering requires a configured node", error.message
    assert_no_enqueued_jobs
    assert_equal 0, WateringEvent.count
  end

  test "stop rejects a zone-only manual stop command" do
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1")

    error = assert_raises(ArgumentError) { WateringCommand.stop(zone) }
    assert_equal "zone-level stop_watering is unavailable until stop_all is implemented", error.message
    assert_no_enqueued_jobs
    assert_equal 0, WateringEvent.count
  end

  test "timeout watchdog is scheduled even though CommandPublishJob is never performed here" do
    ConnectionSetting.create!(irrigation_line_count: 1)
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "actuator-zone1", zone: zone, last_seen_at: Time.current, crop_profile: crop, irrigation_line: 1)

    # ActiveJob's :test adapter never actually performs enqueued jobs unless
    # asked to -- this demonstrates the watchdog scheduling doesn't depend
    # on CommandPublishJob (or MqttClient) ever running, only on
    # WateringCommand itself, so a broker outage can't silently swallow it.
    result = WateringCommand.start_node(node)

    assert_enqueued_with(job: ActuatorCommandTimeoutJob, args: [{ idempotency_key: result.payload[:idempotency_key], timeout_seconds: 75 }])
    assert_enqueued_with(job: CommandPublishJob, args: [result.payload])
    assert_equal node.node_id, result.payload[:node_id]
    refute_includes result.payload, :irrigation_line
  end

  test "start_node enqueues a canonical UTC timestamp while preserving the event timestamp" do
    ConnectionSetting.create!(irrigation_line_count: 1)
    crop = create(:crop_profile, max_pulse_runtime_sec: 45)
    zone = create(:zone, zone_id: "zone1")
    node = Node.create!(node_id: "actuator-zone1", zone: zone, last_seen_at: Time.current, crop_profile: crop, irrigation_line: 1)
    command_time = Time.utc(2026, 9, 14, 16, 52, 12, 987_654)

    result = nil
    travel_to(command_time, with_usec: true) do
      result = WateringCommand.start_node(node)
    end

    assert_equal "2026-09-14T16:52:12Z", result.payload[:issued_at]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, result.payload[:issued_at])
    refute_includes result.payload[:issued_at], "."
    assert_equal command_time, result.event.issued_at
    assert_equal node.node_id, result.payload[:node_id]
    assert_equal "start_watering", result.payload[:command]
    assert_equal 45, result.payload[:runtime_seconds]
    assert_equal "manual_trigger", result.payload[:reason]
    assert_match(/\Aactuator-zone1-20260914T165212Z-/, result.payload[:idempotency_key])
    assert_enqueued_with(job: CommandPublishJob, args: [result.payload])
  end

  test "start_node rejects a node without an irrigation line" do
    crop = create(:crop_profile)
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1", zone: zone, crop_profile: crop, last_seen_at: Time.current)

    assert_raises(ArgumentError, /irrigation line/) { WateringCommand.start_node(node) }
    assert_no_enqueued_jobs
    assert_equal 0, WateringEvent.count
  end

  test "start_node rejects an otherwise configured Node in an inactive Zone before publishing" do
    ConnectionSetting.create!(irrigation_line_count: 1)
    crop = create(:crop_profile)
    zone = create(:zone, active: false)
    node = Node.create!(node_id: "sensor-zone1-ch0", zone: zone, crop_profile: crop, irrigation_line: 1, last_seen_at: Time.current)
    clear_enqueued_jobs

    assert_raises(ArgumentError, /active assigned zone/) { WateringCommand.start_node(node) }
    assert_no_enqueued_jobs
    assert_equal 0, WateringEvent.count
  end

  test "start_node rejects a logical line beyond installed capacity without publishing" do
    ConnectionSetting.create!(irrigation_line_count: 4)
    crop = create(:crop_profile)
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1-ch3", zone: zone, crop_profile: crop, irrigation_line: 8, last_seen_at: Time.current)
    clear_enqueued_jobs

    assert_raises(ArgumentError, /not supported by installed actuator capacity/) { WateringCommand.start_node(node) }
    assert_equal 8, node.reload.irrigation_line
    assert_no_enqueued_jobs
    assert_equal 0, WateringEvent.count
  end

  test "line equal to installed capacity is eligible for manual watering" do
    ConnectionSetting.create!(irrigation_line_count: 8)
    crop = create(:crop_profile)
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1-ch3", zone: zone, crop_profile: crop, irrigation_line: 8, last_seen_at: Time.current)

    assert node.irrigation_line_supported?
    assert WateringCommand.start_node(node).event.persisted?
  end

  test "start_node fails closed when installed capacity is zero" do
    ConnectionSetting.create!(irrigation_line_count: 0)
    crop = create(:crop_profile)
    zone = create(:zone)
    node = Node.create!(node_id: "sensor-zone1-ch0", zone: zone, crop_profile: crop, irrigation_line: 1, last_seen_at: Time.current)
    clear_enqueued_jobs

    assert_raises(ArgumentError, /not supported by installed actuator capacity/) { WateringCommand.start_node(node) }
    assert_no_enqueued_jobs
  end
end
