require "test_helper"

class WateringEventsTest < ActionDispatch::IntegrationTest
  setup do
    crop = create(:crop_profile, crop_name: "Tomato")
    @zone1 = create(:zone, zone_id: "zone1", name: "Greenhouse Zone 1", crop_profile: crop)
    @zone2 = create(:zone, zone_id: "zone2", name: "Greenhouse Zone 2", crop_profile: crop)
  end

  test "watering events page renders presets filters and export controls" do
    WateringEvent.create!(
      zone: @zone1,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.utc(2026, 5, 14, 12, 0),
      idempotency_key: "zone1-completed-001",
      status: "completed"
    )

    get watering_events_path(timeframe: "custom", from: "2026-05-14", to: "2026-05-14")

    assert_response :success
    assert_includes response.body, "Watering Events"
    assert_includes response.body, "Last 24 Hours"
    assert_includes response.body, "Completed"
    assert_includes response.body, "Faults"
    assert_includes response.body, "Manual"
    assert_includes response.body, "Long Runtime"
    assert_includes response.body, "Columns"
    assert_includes response.body, "Export CSV"
    assert_includes response.body, "Watering Results"
  end

  test "watering events filters by zone command reason status and runtime" do
    WateringEvent.create!(
      zone: @zone1,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.utc(2026, 5, 14, 12, 0),
      idempotency_key: "zone1-completed-001",
      status: "completed"
    )
    WateringEvent.create!(
      zone: @zone1,
      command: "start_watering",
      runtime_seconds: 15,
      reason: "below_dry_threshold",
      issued_at: Time.utc(2026, 5, 14, 13, 0),
      idempotency_key: "zone1-completed-002",
      status: "completed"
    )
    WateringEvent.create!(
      zone: @zone2,
      command: "stop_watering",
      runtime_seconds: nil,
      reason: "manual_stop",
      issued_at: Time.utc(2026, 5, 14, 14, 0),
      idempotency_key: "zone2-fault-001",
      status: "fault"
    )

    get watering_events_path(
      zone_id: @zone1.id,
      command: "start_watering",
      reason: "manual_trigger",
      status: "completed",
      runtime_min: "30",
      timeframe: "custom",
      from: "2026-05-14",
      to: "2026-05-14"
    )

    assert_response :success
    assert_includes response.body, "manual_trigger"
    assert_includes response.body, "45"
    assert_includes response.body, "2026-05-14 12:00:00 UTC"
    assert_not_includes response.body, "2026-05-14 13:00:00 UTC"
    assert_not_includes response.body, "2026-05-14 14:00:00 UTC"
  end

  test "watering events supports sorting pagination and csv export" do
    WateringEvent.create!(
      zone: @zone1,
      command: "start_watering",
      runtime_seconds: 45,
      reason: "manual_trigger",
      issued_at: Time.utc(2026, 5, 14, 12, 0),
      idempotency_key: "zone1-completed-001",
      status: "completed"
    )
    WateringEvent.create!(
      zone: @zone1,
      command: "start_watering",
      runtime_seconds: 15,
      reason: "manual_trigger",
      issued_at: Time.utc(2026, 5, 14, 13, 0),
      idempotency_key: "zone1-completed-002",
      status: "completed"
    )
    WateringEvent.create!(
      zone: @zone1,
      command: "start_watering",
      runtime_seconds: 25,
      reason: "manual_trigger",
      issued_at: Time.utc(2026, 5, 14, 14, 0),
      idempotency_key: "zone1-completed-003",
      status: "completed"
    )

    get watering_events_path(
      timeframe: "custom",
      from: "2026-05-14",
      to: "2026-05-14",
      sort: "runtime_seconds",
      direction: "asc",
      per_page: 2,
      columns: %w[issued_at runtime_seconds status]
    )

    assert_response :success
    assert_includes response.body, "2026-05-14 13:00:00 UTC"
    assert_includes response.body, "2026-05-14 14:00:00 UTC"
    assert_not_includes response.body, "2026-05-14 12:00:00 UTC"

    get watering_events_path(
      format: :csv,
      timeframe: "custom",
      from: "2026-05-14",
      to: "2026-05-14",
      columns: %w[issued_at runtime_seconds status]
    )

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Issued At,Runtime (s),Status"
    assert_not_includes response.body, "Watering Reason"
  end
end
