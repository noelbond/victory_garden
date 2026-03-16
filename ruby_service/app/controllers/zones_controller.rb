class ZonesController < ApplicationController
  before_action :set_zone, only: %i[show edit update destroy water_now stop_watering toggle_active]

  def index
    @zones = Zone.includes(:crop_profile).order(:zone_id)
    @latest_readings = latest_readings_for(@zones)
    @latest_statuses = latest_statuses_for(@zones)
  end

  def show
    @latest_reading = @zone.sensor_readings.order(recorded_at: :desc).first
    @recent_readings = @zone.sensor_readings.order(recorded_at: :desc).limit(10)
    @last_watering_event = @zone.watering_events.order(issued_at: :desc).first
    @latest_actuator_status = @zone.actuator_statuses.order(recorded_at: :desc).first
    @recent_faults = @zone.faults.order(recorded_at: :desc).limit(5)

    @range = params[:range].presence || "month"
    @water_usage = water_usage_series(@zone, @range)
  end

  def new
    @zone = Zone.new
    load_crop_profiles
  end

  def edit
    load_crop_profiles
  end

  def create
    @zone = Zone.new(zone_params_with_allowed_hours)
    if @zone.save
      redirect_to zones_path, notice: "Zone created."
    else
      load_crop_profiles
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @zone.update(zone_params_with_allowed_hours)
      redirect_to zones_path, notice: "Zone updated."
    else
      load_crop_profiles
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @zone.destroy
    redirect_to zones_path, notice: "Zone removed."
  end

  def water_now
    command = {
      command: "start_watering",
      zone_id: @zone.zone_id,
      runtime_seconds: @zone.crop_profile.max_pulse_runtime_sec,
      reason: "manual_trigger",
      issued_at: Time.current,
      idempotency_key: "#{@zone.zone_id}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
    }

    WateringEvent.create!(
      zone: @zone,
      command: command[:command],
      runtime_seconds: command[:runtime_seconds],
      reason: command[:reason],
      issued_at: command[:issued_at],
      idempotency_key: command[:idempotency_key],
      status: "queued"
    )
    CommandPublishJob.perform_later(command)
    redirect_to @zone, notice: "Watering command queued."
  end

  def stop_watering
    command = {
      command: "stop_watering",
      zone_id: @zone.zone_id,
      runtime_seconds: nil,
      reason: "manual_stop",
      issued_at: Time.current,
      idempotency_key: "#{@zone.zone_id}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
    }

    WateringEvent.create!(
      zone: @zone,
      command: command[:command],
      runtime_seconds: command[:runtime_seconds],
      reason: command[:reason],
      issued_at: command[:issued_at],
      idempotency_key: command[:idempotency_key],
      status: "queued"
    )
    CommandPublishJob.perform_later(command)
    redirect_to @zone, notice: "Stop command queued."
  end

  def toggle_active
    @zone.update!(active: !@zone.active)
    redirect_to @zone, notice: "Zone updated."
  end

  private

  def set_zone
    @zone = Zone.find(params[:id])
  end

  def load_crop_profiles
    @crop_profiles = CropProfile.order(:crop_name)
  end

  def zone_params
    params.require(:zone).permit(:name, :crop_profile_id, :active)
  end

  def zone_params_with_allowed_hours
    attrs = zone_params
    start_hour = params.dig(:zone, :allowed_start_hour)
    end_hour = params.dig(:zone, :allowed_end_hour)

    if start_hour.present? && end_hour.present?
      attrs[:allowed_hours] = {
        "start_hour" => start_hour.to_i,
        "end_hour" => end_hour.to_i
      }
    else
      attrs[:allowed_hours] = nil
    end

    attrs
  end

  def water_usage_series(zone, range)
    scope = zone.watering_events.where(command: "start_watering")
    case range
    when "week"
      scope.where(issued_at: 1.week.ago..Time.current).group_by_period(:day, :issued_at).sum(:runtime_seconds)
    when "month"
      scope.where(issued_at: 1.month.ago..Time.current).group_by_period(:day, :issued_at).sum(:runtime_seconds)
    when "year"
      scope.where(issued_at: 1.year.ago..Time.current).group_by_period(:month, :issued_at).sum(:runtime_seconds)
    when "ytd"
      start = Time.current.beginning_of_year
      scope.where(issued_at: start..Time.current).group_by_period(:month, :issued_at).sum(:runtime_seconds)
    else
      scope.where(issued_at: 1.month.ago..Time.current).group_by_period(:day, :issued_at).sum(:runtime_seconds)
    end
  end

  def latest_readings_for(zones)
    ids = zones.map(&:id)
    return {} if ids.empty?

    rows = SensorReading
      .select("DISTINCT ON (zone_id) *")
      .where(zone_id: ids)
      .order("zone_id, recorded_at DESC")
    rows.index_by(&:zone_id)
  end

  def latest_statuses_for(zones)
    ids = zones.map(&:id)
    return {} if ids.empty?

    rows = ActuatorStatus
      .select("DISTINCT ON (zone_id) *")
      .where(zone_id: ids)
      .order("zone_id, recorded_at DESC")
    rows.index_by(&:zone_id)
  end
end
