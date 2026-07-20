require "test_helper"

class GreenhouseTemperatureAlertTest < ActiveSupport::TestCase
  setup do
    @zone = create(:zone)
  end

  test "applies warning hysteresis" do
    assert_equal "warning", alert_at_f(91).status
    create_reading(91, "warning")
    assert_equal "warning", alert_at_f(88).status
    assert_equal "normal", alert_at_f(87.9).status
  end

  test "applies critical hysteresis and steps down through warning" do
    assert_equal "critical", alert_at_f(96).status
    create_reading(96, "critical")
    assert_equal "critical", alert_at_f(93).status
    assert_equal "warning", alert_at_f(92.9).status
    assert_equal "normal", alert_at_f(87.9).status
  end

  test "deduplicates critical faults and permits a new fault after recovery" do
    first = alert_at_f(96)
    first.record!(status: first.status)
    alert_at_f(97).record!(status: "critical")
    assert_equal 1, open_faults.count

    alert_at_f(92).record!(status: "warning")
    assert_equal 0, open_faults.count

    alert_at_f(96).record!(status: "critical")
    assert_equal 1, open_faults.count
    assert_equal 2, @zone.faults.where(fault_code: GreenhouseTemperatureAlert::FAULT_CODE).count
  end

  private

  def alert_at_f(temperature_f)
    GreenhouseTemperatureAlert.new(
      zone: @zone,
      temperature_c: (temperature_f - 32.0) * 5.0 / 9.0,
      recorded_at: Time.current
    )
  end

  def create_reading(temperature_f, status)
    @zone.sensor_readings.create!(
      node_id: "sensor-ch0",
      recorded_at: 1.minute.ago,
      air_temperature_c: (temperature_f - 32.0) * 5.0 / 9.0,
      greenhouse_alert_status: status
    )
  end

  def open_faults
    @zone.faults.where(fault_code: GreenhouseTemperatureAlert::FAULT_CODE, resolved_at: nil)
  end
end
