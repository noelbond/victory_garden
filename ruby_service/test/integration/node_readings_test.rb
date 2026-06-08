require "test_helper"

class NodeReadingsTest < ActionDispatch::IntegrationTest
  setup do
    crop = create(:crop_profile, crop_name: "Tomato")
    @zone = create(:zone, zone_id: "zone1", name: "Greenhouse Zone 1", crop_profile: crop)
    @node = Node.create!(node_id: "pico-w-zone1-a", zone: @zone, last_seen_at: Time.current)
  end

  test "node readings page renders reading-history style filters and results" do
    SensorReading.create!(
      zone: @zone,
      node_id: @node.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 15),
      moisture_raw: 510,
      moisture_percent: 12.0,
      publish_reason: "interval",
      health: "degraded",
      last_error: "sensor glitch",
      raw_payload: {}
    )

    get readings_node_path(@node, timeframe: "custom", from: "2026-05-12", to: "2026-05-12")

    assert_response :success
    assert_includes response.body, "Node Readings"
    assert_includes response.body, "Filters"
    assert_includes response.body, "Publish Reason"
    assert_includes response.body, "Columns"
    assert_includes response.body, "Reading Results"
    assert_includes response.body, "Export CSV"
    assert_includes response.body, "Publish Gaps"
  end

  test "node readings filters and sorts results" do
    SensorReading.create!(
      zone: @zone,
      node_id: @node.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 15),
      moisture_raw: 510,
      moisture_percent: 12.0,
      publish_reason: "interval",
      health: "degraded",
      last_error: "sensor glitch",
      raw_payload: {}
    )
    SensorReading.create!(
      zone: @zone,
      node_id: @node.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 30),
      moisture_raw: 610,
      moisture_percent: 42.0,
      publish_reason: "request_reading",
      health: "ok",
      last_error: "none",
      raw_payload: {}
    )

    get readings_node_path(
      @node,
      timeframe: "custom",
      from: "2026-05-12",
      to: "2026-05-12",
      errors_only: "1",
      sort: "moisture_percent",
      direction: "asc",
      columns: %w[recorded_at moisture_percent last_error]
    )

    assert_response :success
    assert_includes response.body, "sensor glitch"
    assert_not_includes response.body, "42.0%"
    assert_not_includes response.body, "sort=moisture_raw"
  end

  test "node readings exports csv for selected columns" do
    SensorReading.create!(
      zone: @zone,
      node_id: @node.node_id,
      recorded_at: Time.utc(2026, 5, 12, 9, 15),
      moisture_raw: 510,
      moisture_percent: 12.0,
      publish_reason: "interval",
      health: "degraded",
      last_error: "sensor glitch",
      raw_payload: {}
    )

    get readings_node_path(@node, format: :csv, timeframe: "custom", from: "2026-05-12", to: "2026-05-12", columns: %w[recorded_at moisture_percent moisture_raw])

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Recorded At,Moisture %,Moisture Raw"
    assert_not_includes response.body, "Publish Reason"
  end
end
