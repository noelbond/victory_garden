class NodesController < ApplicationController
  include HistoryFiltering

  DEFAULT_HISTORY_WINDOW = 7.days
  DEFAULT_TIMEFRAME = "last_7d"
  DEFAULT_PER_PAGE = 25
  MAX_HISTORY_LIMIT = 250
  TIMEFRAME_OPTIONS = {
    "last_24h" => "Last 24 Hours",
    "last_7d" => "Last 7 Days",
    "last_30d" => "Last 30 Days",
    "last_90d" => "Last 90 Days",
    "ytd" => "Year to Date",
    "custom" => "Custom Range"
  }.freeze
  FRESHNESS_OPTIONS = {
    "" => "Any Freshness",
    "stale" => "Stale Only",
    "offline" => "Offline Only",
    "stale_or_offline" => "Stale + Offline"
  }.freeze
  MAX_PER_PAGE = MAX_HISTORY_LIMIT
  PER_PAGE_OPTIONS = [25, 50, 100, 250].freeze
  SORTABLE_COLUMNS = {
    "recorded_at" => "sensor_readings.recorded_at",
    "moisture_percent" => "sensor_readings.moisture_percent",
    "moisture_raw" => "sensor_readings.moisture_raw",
    "air_temperature_f" => "sensor_readings.air_temperature_c",
    "humidity_percent" => "sensor_readings.humidity_percent",
    "greenhouse_alert_status" => "sensor_readings.greenhouse_alert_status",
    "health" => "sensor_readings.health",
    "last_error" => "sensor_readings.last_error",
    "publish_reason" => "sensor_readings.publish_reason",
    "wifi_rssi" => "sensor_readings.wifi_rssi",
    "wake_count" => "sensor_readings.wake_count",
    "uptime_seconds" => "sensor_readings.uptime_seconds"
  }.freeze
  TABLE_COLUMNS = [
    ["recorded_at", "Recorded At"],
    ["moisture_percent", "Moisture %"],
    ["moisture_raw", "Moisture Raw"],
    ["air_temperature_f", "Air Temp F"],
    ["humidity_percent", "Humidity %"],
    ["greenhouse_alert_status", "Greenhouse Alert"],
    ["health", "Health"],
    ["last_error", "Last Error"],
    ["publish_reason", "Publish Reason"],
    ["wifi_rssi", "Wi-Fi RSSI"],
    ["wake_count", "Wake Count"],
    ["uptime_seconds", "Uptime"]
  ].freeze
  DEFAULT_COLUMNS = TABLE_COLUMNS.map(&:first).freeze

  before_action :set_node, only: %i[show readings assign unassign publish_config request_reading manually_water reboot crop_profile update_calibration]
  before_action :load_show_dependencies, only: %i[show update_calibration]

  def index
    @nodes = Node.includes(:zone).order(last_seen_at: :desc, node_id: :asc)
    @unassigned_nodes = @nodes.select { |node| !node.assigned? }
    @assigned_nodes = @nodes.select(&:assigned?)
    @unassigned_node_groups = Node.group_by_device(@unassigned_nodes)
    @assigned_node_groups = Node.group_by_device(@assigned_nodes)

    @distinct_zone_ids = Node.distinct.pluck(:zone_id)
  end

  def show
  end

  def readings
    @timeframe = selected_timeframe
    @from, @to = resolved_range
    @per_page = resolved_per_page
    @page = [params[:page].to_i, 1].max
    @selected_columns = resolved_columns
    @expected_interval_seconds = @node.expected_publish_interval_seconds
    @publish_reason_options = SensorReading.where(node_id: @node.node_id).distinct.order(:publish_reason).pluck(:publish_reason).compact.reject(&:blank?)
    @health_options = %w[ok degraded]
    @freshness_options = FRESHNESS_OPTIONS.map { |value, label| [label, value] }

    scope = filtered_readings_scope
    @total_readings = scope.count
    ordered_scope = scope.order(Arel.sql("#{SORTABLE_COLUMNS.fetch(sort_column)} #{sort_direction.upcase}, sensor_readings.id #{secondary_sort_direction}"))
    @publish_gaps = publish_gaps_for(scope.reorder(recorded_at: :asc).to_a, @expected_interval_seconds)
    @error_reading_count = scope.where.not(last_error: [nil, "", "none"]).count
    @active_filter_count = active_filter_count
    @total_pages = [(@total_readings.to_f / @per_page).ceil, 1].max
    @page = [@page, @total_pages].min
    @readings = ordered_scope.offset((@page - 1) * @per_page).limit(@per_page)

    respond_to do |format|
      format.html
      format.csv do
        send_data(
          readings_csv(ordered_scope),
          filename: "#{@node.node_id}-readings-#{@from.to_date}-to-#{@to.to_date}.csv",
          type: "text/csv"
        )
      end
    end
  end

  def assign
    zone = Zone.find(params.require(:zone_id))

    @node.update!(zone: zone)
    PublishNodeConfigJob.perform_later(@node.id)

    redirect_to node_path(@node), notice: "Node assigned to #{zone.name.presence || zone.zone_id}."
  end

  def unassign
    if @node.zone.present?
      @node.update!(zone: nil)
      PublishNodeConfigJob.perform_later(@node.id)
    end

    redirect_to nodes_path, notice: "Node unassigned."
  end

  def publish_config
    PublishNodeConfigJob.perform_later(@node.id)
    redirect_to resolved_return_path, notice: "Node config publish queued."
  end

  def request_reading
    return unless require_assigned_zone_for_command("Assign the node before requesting a reading.")
    return unless require_online_for_command("#{@node.display_name} hasn't reported in a while and appears offline; a reading request would likely just time out.")

    queue_reading_request(@node)
    redirect_to resolved_return_path, notice: reading_request_notice_for(@node)
  end

  def manually_water
    return unless require_assigned_zone_for_command("Assign the node before watering it.")
    return unless require_online_for_command("#{@node.display_name} hasn't reported in a while and appears offline; watering would likely just time out.")

    unless @node.watering_configured?
      redirect_to resolved_return_path, alert: "Assign a crop profile and pump output before watering #{@node.display_name}."
      return
    end

    if @node.zone.watering_events.blocking_start_commands.where(node_id: @node.node_id).exists?
      redirect_to resolved_return_path, alert: "Watering is already active for #{@node.display_name}."
      return
    end

    WateringCommand.start_node(@node)
    redirect_to resolved_return_path, notice: "Watering command queued for #{@node.display_name}."
  end

  def reboot
    return unless require_assigned_zone_for_command("Assign the node before sending a reboot command.")

    issued_at = Time.current
    command_id = "#{@node.node_id}-#{issued_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}-reboot"

    NodeCommand.create!(
      zone: @node.zone,
      node_id: @node.node_id,
      command: "reboot",
      command_id: command_id,
      status: "queued",
      issued_at: issued_at
    )

    # Scheduled independently of RebootNodeJob's own success so a publish
    # failure (even after that job's own retries are exhausted) still
    # surfaces as a visible NODE_COMMAND_TIMEOUT fault instead of leaving
    # this command stuck "queued" forever.
    NodeCommandTimeoutJob
      .set(wait: RebootNodeJob::TIMEOUT_SECONDS.seconds)
      .perform_later(command_id: command_id, timeout_seconds: RebootNodeJob::TIMEOUT_SECONDS)

    RebootNodeJob.perform_later(
      zone_id: @node.zone.zone_id,
      command_id: command_id,
      node_id: @node.node_id
    )
    redirect_to resolved_return_path, notice: "Node reboot queued."
  end

  def crop_profile
    return unless require_assigned_zone_for_command("Assign the node before applying a crop profile.")

    @node.update!(node_watering_params)

    redirect_to node_path(@node), notice: "Plant watering profile updated for #{@node.display_name}."
  end

  def update_calibration
    if @node.update(node_calibration_params)
      redirect_to resolved_return_path, notice: "Node calibration updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def resolved_return_path
    url_from(params[:return_to]).presence || node_path(@node)
  end

  def require_assigned_zone_for_command(message)
    if @node.zone.blank?
      redirect_to resolved_return_path, alert: message
      return false
    end

    true
  end

  def require_online_for_command(message)
    if @node.offline?
      redirect_to resolved_return_path, alert: message
      return false
    end

    true
  end

  def set_node
    @node = Node.find(params[:id])
  end

  def load_show_dependencies
    @available_zones = Zone.order(:zone_id)
    @crop_profiles = CropProfile.order(:crop_name)
  end

  def node_calibration_params
    params.require(:node).permit(:moisture_raw_dry, :moisture_raw_wet)
  end

  def node_watering_params
    params.permit(:crop_profile_id, :irrigation_line).tap do |permitted|
      permitted[:crop_profile_id] = permitted[:crop_profile_id].presence
      permitted[:irrigation_line] = permitted[:irrigation_line].to_i if permitted[:irrigation_line].present?
    end
  end

  def filtered_readings_scope
    scope = SensorReading.where(node_id: @node.node_id, recorded_at: @from..@to)
    scope = scope.where(health: params[:health]) if @health_options.include?(params[:health])
    scope = scope.where(publish_reason: params[:publish_reason]) if params[:publish_reason].present?
    scope = scope.where.not(last_error: [nil, "", "none"]) if params[:errors_only] == "1"
    scope = scope.where("sensor_readings.moisture_percent >= ?", Float(params[:moisture_min])) if valid_float_param?(:moisture_min)
    scope = scope.where("sensor_readings.moisture_percent <= ?", Float(params[:moisture_max])) if valid_float_param?(:moisture_max)
    apply_freshness_filter(scope)
  end

  def active_filter_count
    [
      params[:errors_only] == "1",
      params[:health].present?,
      params[:freshness].present?,
      params[:publish_reason].present?,
      params[:moisture_min].present?,
      params[:moisture_max].present?,
      @timeframe == "custom"
    ].count(true)
  end

  def freshness_interval_seconds_for(_reading)
    @expected_interval_seconds
  end

  def publish_gaps_for(readings, expected_interval_seconds)
    threshold = expected_interval_seconds * 1.5

    readings.each_cons(2).filter_map do |previous, current|
      gap_seconds = current.recorded_at - previous.recorded_at
      next unless gap_seconds > threshold

      {
        after: previous.recorded_at,
        resumed_at: current.recorded_at,
        duration_seconds: gap_seconds,
        missed_intervals: [((gap_seconds / expected_interval_seconds).floor - 1), 0].max
      }
    end
  end

  def readings_csv(scope)
    csv_string_for_scope(scope, tie_breaker: "sensor_readings.id #{secondary_sort_direction}", trailing_newline: true)
  end

  def csv_value_for(reading, column)
    reading.csv_value(column)
  end

end
