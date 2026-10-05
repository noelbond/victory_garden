require "test_helper"
require Rails.root.join("script/portfolio_demo_data")

class PortfolioDemoDataTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    @now = Time.zone.parse("2026-09-30 14:00:00")
    travel_to @now
    PortfolioDemoData.seed!(now: @now)
  end

  teardown do
    clear_enqueued_jobs
    travel_back
  end

  test "creates canonical screenshot data with past and fresh telemetry" do
    assert_equal %w[herb-bench north-canopy], Zone.order(:zone_id).pluck(:zone_id)
    assert_equal 8, Node.count
    assert Zone.all.all?(&:canonical_sensor_package_nodes?)
    assert_equal (1..8).to_a, Node.order(:irrigation_line).pluck(:irrigation_line)
    assert Node.all.all?(&:irrigation_line_supported?)
    assert Node.all.all? { |node| node.name.present? && node.crop_profile.present? }
    assert Node.all.all? { |node| node.config_status == "applied" && node.config_acknowledged_at.present? }

    assert_equal 8 * PortfolioDemoData::READINGS_PER_NODE, SensorReading.count
    assert_equal 0, SensorReading.where("recorded_at >= ?", @now).count
    assert_equal 0, SensorReading.where(recorded_at: ...(@now - 31.days)).count
    assert_equal 0, SensorReading.where(air_temperature_c: nil).count
    assert_equal 0, SensorReading.where(humidity_percent: nil).count
    assert_equal 0, SensorReading.where(moisture_percent: nil).count
    assert_equal 0, SensorReading.where.not(ip_address: nil).count
    assert Node.all.all? { |node| node.last_seen_at.between?(@now - 2.minutes, @now) }
  end

  test "creates correlated completed waterings without faults" do
    assert_equal 32, WateringEvent.count
    assert_equal [ "completed" ], WateringEvent.distinct.pluck(:status)
    assert_equal 0, WateringEvent.where(node_id: nil).count
    assert_equal Node.order(:node_id).pluck(:node_id), WateringEvent.distinct.order(:node_id).pluck(:node_id)
    assert_equal 32, ActuatorStatus.where(state: "COMPLETED").count
    assert_equal 0, Fault.where(resolved_at: nil).count
  end

  test "satisfies real onboarding readiness and serves the dashboard" do
    get root_path

    assert_response :success
    assert_includes response.body, "Garden Dashboard"
    refute_includes response.body, "Setup Incomplete"
    assert_includes response.body, "8 / 8"
    assert_includes response.body, "North Canopy"
    assert_includes response.body, "Herb Bench"
  end

  test "refuses to overwrite non-portfolio application data" do
    Zone.create!(zone_id: "existing-install", name: "Existing Install")

    error = assert_raises(RuntimeError) { PortfolioDemoData.seed!(now: @now) }

    assert_includes error.message, "contains non-portfolio application data"
  end
end
