require "test_helper"

class ReadingHistoryTest < ActionDispatch::IntegrationTest
  setup do
    @crop = create(:crop_profile, crop_name: "Tomato")
    @zone1 = create(:zone, zone_id: "zone1", name: "Greenhouse Zone 1", crop_profile: @crop)
    @zone2 = create(:zone, zone_id: "zone2", name: "Greenhouse Zone 2", crop_profile: @crop)
    @node1 = Node.create!(node_id: "pico-w-zone1-a", zone: @zone1, last_seen_at: Time.current)
    @node2 = Node.create!(node_id: "pico-w-zone1-b", zone: @zone1, last_seen_at: Time.current)
    @node3 = Node.create!(node_id: "pico-w-zone2-a", zone: @zone2, last_seen_at: Time.current)
  end

  test "reading history page renders presets readings tab and trend tab controls" do
    SensorReading.create!(
      zone: @zone1,
      node_id: @node1.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 15),
      moisture_raw: 510,
      moisture_percent: 12.0,
      publish_reason: "interval",
      health: "degraded",
      last_error: "sensor glitch",
      raw_payload: {}
    )

    get reading_history_path(zone_id: @zone1.id, timeframe: "custom", from: "2026-05-12", to: "2026-05-12")

    assert_response :success
    assert_includes response.body, "Reading History"
    assert_includes response.body, "Last 24 Hours"
    assert_includes response.body, "Errors"
    assert_includes response.body, "Stale + Offline"
    assert_includes response.body, "Dry Range"
    assert_includes response.body, "Trends 30d"
    assert_includes response.body, "Readings"
    assert_includes response.body, "Trends"
    assert_includes response.body, "All Nodes"
    assert_includes response.body, @node1.node_id
    assert_includes response.body, @node2.node_id
    assert_includes response.body, "Columns"
    assert_not_includes response.body, "id=\"node_id\""
    assert_includes response.body, "Reading Results"
    assert_not_includes response.body, "Completed Waterings"
  end

  test "reading history trends tab renders moisture and watering charts" do
    SensorReading.create!(
      zone: @zone1,
      node_id: @node1.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 15),
      moisture_raw: 510,
      moisture_percent: 12.0,
      publish_reason: "interval",
      health: "degraded",
      last_error: "sensor glitch",
      raw_payload: {}
    )
    WateringEvent.create!(
      zone: @zone1,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.utc(2026, 5, 12, 10, 0),
      idempotency_key: "zone1-completed-001",
      status: "completed"
    )

    get reading_history_path(zone_id: @zone1.id, section: "trends", timeframe: "custom", from: "2026-05-12", to: "2026-05-12")

    assert_response :success
    assert_includes response.body, "Trends"
    assert_includes response.body, "Total Waterings Over Time"
    assert_includes response.body, "Greenhouse Zone 1 Moisture Over Time"
    assert_includes response.body, "#{@node1.node_id} Moisture %"
    assert_not_includes response.body, "Reading Results"
  end

  test "reading history shows custom date fields only when custom timeframe is selected" do
    get reading_history_path

    assert_response :success
    assert_includes response.body, "data-reading-history-custom-range hidden"

    get reading_history_path(timeframe: "custom")

    assert_response :success
    assert_includes response.body, "<label for=\"from\">From</label>"
    assert_includes response.body, "<label for=\"to\">To</label>"
    assert_not_includes response.body, "data-reading-history-custom-range hidden"
  end

  test "reading history filters by node tab freshness errors and moisture range" do
    SensorReading.create!(
      zone: @zone1,
      node_id: @node1.node_id,
      recorded_at: 90.minutes.ago.utc,
      moisture_raw: 510,
      moisture_percent: 12.0,
      publish_reason: "interval",
      health: "degraded",
      last_error: "sensor glitch",
      raw_payload: {}
    )
    SensorReading.create!(
      zone: @zone1,
      node_id: @node2.node_id,
      recorded_at: 20.minutes.ago.utc,
      moisture_raw: 640,
      moisture_percent: 42.0,
      publish_reason: "request_reading",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )
    SensorReading.create!(
      zone: @zone2,
      node_id: @node3.node_id,
      recorded_at: 3.hours.ago.utc,
      moisture_raw: 700,
      moisture_percent: 78.0,
      publish_reason: "interval",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )

    get reading_history_path(
      zone_id: @zone1.id,
      node_id: @node1.id,
      freshness: "stale_or_offline",
      errors_only: "1",
      moisture_max: "20"
    )

    assert_response :success
    assert_includes response.body, @node1.node_id
    assert_includes response.body, "sensor glitch"
    assert_not_includes response.body, "42.0%"
    assert_not_includes response.body, "78.0%"
    refute_includes response.body, "Clear Node:"
  end

  test "reading history supports sorting pagination and column picker" do
    SensorReading.create!(
      zone: @zone1,
      node_id: @node1.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 15),
      moisture_raw: 300,
      moisture_percent: 35.0,
      publish_reason: "interval",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )
    SensorReading.create!(
      zone: @zone1,
      node_id: @node1.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 30),
      moisture_raw: 100,
      moisture_percent: 10.0,
      publish_reason: "interval",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )
    SensorReading.create!(
      zone: @zone1,
      node_id: @node1.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 45),
      moisture_raw: 200,
      moisture_percent: 20.0,
      publish_reason: "interval",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )

    get reading_history_path(
      timeframe: "custom",
      from: "2026-05-12",
      to: "2026-05-12",
      sort: "moisture_percent",
      direction: "asc",
      per_page: 2,
      columns: %w[recorded_at node moisture_percent]
    )

    assert_response :success
    assert_includes response.body, "2026-05-12 09:30:00 UTC"
    assert_includes response.body, "2026-05-12 09:45:00 UTC"
    assert_not_includes response.body, "2026-05-12 09:15:00 UTC"
    assert_not_includes response.body, "sort=zone"
    assert_not_includes response.body, "sort=moisture_raw"
    assert_operator response.body.index("2026-05-12 09:30:00 UTC"), :<, response.body.index("2026-05-12 09:45:00 UTC")

    get reading_history_path(
      timeframe: "custom",
      from: "2026-05-12",
      to: "2026-05-12",
      sort: "moisture_percent",
      direction: "asc",
      per_page: 2,
      page: 2,
      columns: %w[recorded_at node moisture_percent]
    )

    assert_response :success
    assert_includes response.body, "2026-05-12 09:15:00 UTC"
    assert_not_includes response.body, "2026-05-12 09:30:00 UTC"
  end

  test "reading history exports csv for the current filtered columns" do
    SensorReading.create!(
      zone: @zone1,
      node_id: @node1.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 15),
      moisture_raw: 510,
      moisture_percent: 12.0,
      publish_reason: "interval",
      health: "degraded",
      last_error: "sensor glitch",
      raw_payload: {}
    )

    get reading_history_path(format: :csv, timeframe: "custom", from: "2026-05-12", to: "2026-05-12", columns: %w[recorded_at node moisture_percent moisture_raw])

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Recorded At,Node,Moisture %,Moisture Raw"
    assert_includes response.body, @node1.node_id
    assert_not_includes response.body, "Battery %"
  end
end
