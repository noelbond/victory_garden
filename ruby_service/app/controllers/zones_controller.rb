class ZonesController < ApplicationController
  before_action :set_zone, only: %i[show edit update destroy water_now stop_watering toggle_active]

  def index
    @zones = Zone.includes(:crop_profile, :nodes).order(:zone_id)
    @latest_readings = latest_readings_for(@zones)
    @latest_statuses = latest_statuses_for(@zones)
    @latest_watering_events = latest_watering_events_for(@zones)
    @open_fault_counts = open_fault_counts_for(@zones)
    @unclaimed_node_count = Node.unclaimed.count
    @summary = {
      zones: @zones.count,
      active_zones: @zones.count(&:active?),
      nodes_online: @latest_readings.values.count { |reading| reading.recorded_at > 5.minutes.ago },
      zones_watering: @latest_statuses.values.count { |status| status.state == "RUNNING" },
      open_fault_zones: @open_fault_counts.values.count(&:positive?)
    }
  end

  def show
    @claimed_nodes = @zone.nodes.order(:node_id)
    @recent_readings = @zone.sensor_readings.order(recorded_at: :desc).limit(10)
    @latest_reading = @recent_readings.first
    @last_watering_event = @zone.watering_events.order(issued_at: :desc).first
    @latest_actuator_status = @zone.actuator_statuses.order(recorded_at: :desc).first
    @recent_faults = @zone.faults.order(recorded_at: :desc).limit(5)
    @open_fault_count = @zone.faults.where(resolved_at: nil).count
    @reading_freshness = reading_freshness(@latest_reading)
    @actuator_state_class = actuator_state_class(@latest_actuator_status)
    @zone_attention = zone_attention_items

    @range = params[:range].presence || "month"
    @water_usage = water_usage_series(@zone, @range)
    @moisture_history = moisture_history_series(@zone, @range)
    @history_summary = history_summary(@zone, @range)
    @window_summaries = {
      "Last 24h" => zone_window_summary(@zone, 24.hours),
      "Last 7d" => zone_window_summary(@zone, 7.days)
    }
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

    if start_hour.present? || end_hour.present?
      attrs[:allowed_hours] = {
        "start_hour" => start_hour,
        "end_hour" => end_hour
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

  def moisture_history_series(zone, range)
    scope = moisture_scope_for(zone, range)
    group_period =
      case range
      when "week", "month"
        :day
      when "year", "ytd"
        :month
      else
        :day
      end

    scope.group_by_period(group_period, :recorded_at).average(:moisture_percent)
  end

  def history_summary(zone, range)
    scope = moisture_scope_for(zone, range)
    values = scope.pluck(:moisture_percent).compact.map(&:to_f)

    {
      count: values.size,
      average: values.any? ? (values.sum / values.size).round(1) : nil,
      low: values.any? ? values.min.round(1) : nil,
      high: values.any? ? values.max.round(1) : nil
    }
  end

  def moisture_scope_for(zone, range)
    scope = zone.sensor_readings.where.not(moisture_percent: nil)
    case range
    when "week"
      scope.where(recorded_at: 1.week.ago..Time.current)
    when "month"
      scope.where(recorded_at: 1.month.ago..Time.current)
    when "year"
      scope.where(recorded_at: 1.year.ago..Time.current)
    when "ytd"
      scope.where(recorded_at: Time.current.beginning_of_year..Time.current)
    else
      scope.where(recorded_at: 1.month.ago..Time.current)
    end
  end

  def zone_window_summary(zone, window)
    readings = zone.sensor_readings.where(recorded_at: window.ago..Time.current).where.not(moisture_percent: nil)
    watering = zone.watering_events.where(command: "start_watering", issued_at: window.ago..Time.current)
    values = readings.pluck(:moisture_percent).compact.map(&:to_f)

    {
      readings: values.size,
      avg_moisture: values.any? ? (values.sum / values.size).round(1) : nil,
      min_moisture: values.any? ? values.min.round(1) : nil,
      watering_events: watering.count,
      watering_seconds: watering.sum(:runtime_seconds) || 0
    }
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

  def latest_watering_events_for(zones)
    ids = zones.map(&:id)
    return {} if ids.empty?

    rows = WateringEvent
      .select("DISTINCT ON (zone_id) *")
      .where(zone_id: ids, command: "start_watering")
      .order("zone_id, issued_at DESC")
    rows.index_by(&:zone_id)
  end

  def open_fault_counts_for(zones)
    ids = zones.map(&:id)
    return {} if ids.empty?

    Fault.where(zone_id: ids, resolved_at: nil).group(:zone_id).count
  end

  def reading_freshness(reading)
    return "offline" if reading.blank?
    return "ok" if reading.recorded_at > 5.minutes.ago
    return "stale" if reading.recorded_at > 30.minutes.ago

    "offline"
  end

  def actuator_state_class(status)
    return "offline" if status.blank?

    case status.state
    when "RUNNING", "ACKNOWLEDGED"
      "warn"
    when "FAULT"
      "offline"
    else
      "ok"
    end
  end

  def zone_attention_items
    items = []

    if @latest_reading.blank?
      items << { label: "No readings", detail: "This zone has not published any persisted readings yet.", severity: "warn" }
    elsif @reading_freshness != "ok"
      items << {
        label: "Stale reading",
        detail: "Latest reading is #{view_context.time_ago_in_words(@latest_reading.recorded_at)} old.",
        severity: "warn"
      }
    end

    if @open_fault_count.positive?
      items << {
        label: "Open faults",
        detail: "#{@open_fault_count} unresolved fault#{'s' unless @open_fault_count == 1} need review.",
        severity: "alert"
      }
    end

    if @latest_actuator_status&.state == "RUNNING"
      items << { label: "Watering active", detail: "The actuator is currently reporting RUNNING.", severity: "warn" }
    end

    items
  end
end
