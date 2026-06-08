class ReadingHistoryController < ApplicationController
  include HistoryFiltering

  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 250
  PER_PAGE_OPTIONS = [25, 50, 100, 250].freeze

  DEFAULT_TIMEFRAME = "last_7d"
  DEFAULT_SECTION = "readings"
  TIMEFRAME_OPTIONS = {
    "last_24h" => "Last 24 Hours",
    "last_7d" => "Last 7 Days",
    "last_30d" => "Last 30 Days",
    "last_90d" => "Last 90 Days",
    "ytd" => "Year to Date",
    "custom" => "Custom Range"
  }.freeze
  SECTION_OPTIONS = {
    "readings" => "Readings",
    "trends" => "Trends"
  }.freeze
  FRESHNESS_OPTIONS = {
    "" => "Any Freshness",
    "stale" => "Stale Only",
    "offline" => "Offline Only",
    "stale_or_offline" => "Stale + Offline"
  }.freeze
  FILTER_PRESETS = [
    {label: "Last 24 Hours", params: {timeframe: "last_24h", section: "readings"}},
    {label: "Errors", params: {timeframe: "last_7d", errors_only: "1", section: "readings"}},
    {label: "Stale + Offline", params: {timeframe: "last_7d", freshness: "stale_or_offline", section: "readings"}},
    {label: "Dry Range", params: {timeframe: "last_7d", moisture_max: "20", section: "readings"}},
    {label: "Trends 30d", params: {timeframe: "last_30d", section: "trends"}}
  ].freeze
  SORTABLE_COLUMNS = {
    "recorded_at" => "sensor_readings.recorded_at",
    "zone" => "zones.zone_id",
    "node" => "sensor_readings.node_id",
    "moisture_percent" => "sensor_readings.moisture_percent",
    "moisture_raw" => "sensor_readings.moisture_raw",
    "soil_temp_c" => "sensor_readings.soil_temp_c",
    "battery_percent" => "sensor_readings.battery_percent",
    "health" => "sensor_readings.health",
    "last_error" => "sensor_readings.last_error",
    "publish_reason" => "sensor_readings.publish_reason"
  }.freeze
  TABLE_COLUMNS = [
    ["recorded_at", "Recorded At"],
    ["zone", "Zone"],
    ["node", "Node"],
    ["moisture_percent", "Moisture %"],
    ["moisture_raw", "Moisture Raw"],
    ["soil_temp_c", "Soil Temp C"],
    ["battery_percent", "Battery %"],
    ["health", "Health"],
    ["last_error", "Last Error"],
    ["publish_reason", "Publish Reason"]
  ].freeze
  DEFAULT_COLUMNS = TABLE_COLUMNS.map(&:first).freeze

  def index
    @zones = Zone.includes(:nodes).order(:zone_id)
    @selected_zone = selected_zone
    @zone_nodes = @selected_zone ? @selected_zone.nodes.order(:node_id) : Node.none
    @selected_node = selected_node
    @timeframe = selected_timeframe
    @section = selected_section
    @from, @to = resolved_range
    @per_page = resolved_per_page
    @page = [params[:page].to_i, 1].max
    @selected_columns = resolved_columns

    @publish_reason_options = SensorReading.distinct.order(:publish_reason).pluck(:publish_reason).compact.reject(&:blank?)
    @health_options = %w[ok degraded]
    @freshness_options = FRESHNESS_OPTIONS.map { |value, label| [label, value] }
    @filter_presets = FILTER_PRESETS

    filtered_scope = filtered_readings_scope
    if request.format.csv?
      return send_data(
        readings_csv(filtered_scope),
        filename: "reading-history-#{Time.current.utc.strftime('%Y%m%d-%H%M%S')}.csv",
        type: "text/csv"
      )
    end

    @total_readings = filtered_scope.count
    @total_pages = [(@total_readings.to_f / @per_page).ceil, 1].max
    @page = [@page, @total_pages].min
    @readings = filtered_scope
      .order(Arel.sql("#{SORTABLE_COLUMNS.fetch(sort_column)} #{sort_direction.upcase}, sensor_readings.id #{secondary_sort_direction}"))
      .offset((@page - 1) * @per_page)
      .limit(@per_page)

    @node_tabs = @selected_zone ? @zone_nodes.to_a : []
    @active_filter_count = active_filter_count
    @error_reading_count = filtered_scope.where.not(last_error: [nil, "", "none"]).count

    trend_scope = filtered_watering_events_scope
    chart_zones = @selected_zone ? [@selected_zone] : @zones.to_a
    group_period = watering_group_period

    @waterings_by_zone = chart_zones.each_with_object({}) do |zone, chart_data|
      count = trend_scope.where(zone: zone).count
      chart_data[zone_label(zone)] = count if count.positive?
    end
    @waterings_by_zone = {"No completed waterings" => 0} if @waterings_by_zone.empty?

    @waterings_per_zone_charts = chart_zones.filter_map do |zone|
      data = trend_scope.where(zone: zone).group_by_period(group_period, :issued_at).count
      next if data.empty?

      {label: zone_label(zone), data: data}
    end
    @waterings_total_series = trend_scope.group_by_period(group_period, :issued_at).count

    return unless @selected_zone

    moisture_scope = filtered_readings_scope.where(zone: @selected_zone)
    @zone_moisture_aggregate_series = moisture_scope
      .where.not(moisture_percent: nil)
      .group_by_period(group_period, :recorded_at)
      .average(:moisture_percent)

    @node_moisture_charts = @zone_nodes.filter_map do |node|
      data = moisture_scope
        .where(node_id: node.node_id)
        .where.not(moisture_percent: nil)
        .group_by_period(group_period, :recorded_at)
        .average(:moisture_percent)
      next if data.empty?

      {label: node.node_id, data: data}
    end
  end

  private

  def filtered_readings_scope
    scope = SensorReading.includes(:zone).joins(:zone).where(recorded_at: @from..@to)
    scope = scope.where(zone: @selected_zone) if @selected_zone
    scope = scope.where(node_id: @selected_node.node_id) if @selected_node
    scope = scope.where(health: params[:health]) if @health_options.include?(params[:health])
    scope = scope.where(publish_reason: params[:publish_reason]) if params[:publish_reason].present?
    scope = scope.where.not(last_error: [nil, "", "none"]) if params[:errors_only] == "1"
    scope = scope.where("sensor_readings.moisture_percent >= ?", Float(params[:moisture_min])) if valid_float_param?(:moisture_min)
    scope = scope.where("sensor_readings.moisture_percent <= ?", Float(params[:moisture_max])) if valid_float_param?(:moisture_max)
    scope = apply_freshness_filter(scope)
    scope
  end

  def filtered_watering_events_scope
    scope = WateringEvent.joins(:zone).where(command: "start_watering", status: "completed", issued_at: @from..@to)
    scope = scope.where(zone: @selected_zone) if @selected_zone
    scope
  end

  def selected_zone
    return if params[:zone_id].blank?

    Zone.find_by(id: params[:zone_id])
  end

  def selected_node
    return unless @selected_zone
    return if params[:node_id].blank?

    @selected_zone.nodes.find_by(id: params[:node_id])
  end

  def selected_section
    params[:section].presence_in(SECTION_OPTIONS.keys) || DEFAULT_SECTION
  end

  def watering_group_period
    case @timeframe
    when "last_24h"
      :hour
    when "ytd"
      :month
    when "last_90d"
      :week
    else
      :day
    end
  end

  def zone_label(zone)
    zone.name.presence || zone.zone_id
  end

  def active_filter_count
    [
      @selected_zone.present?,
      @selected_node.present?,
      params[:errors_only] == "1",
      params[:health].present?,
      params[:freshness].present?,
      params[:publish_reason].present?,
      params[:moisture_min].present?,
      params[:moisture_max].present?,
      @timeframe == "custom"
    ].count(true)
  end

  def readings_csv(scope)
    csv_string_for_scope(scope, tie_breaker: "sensor_readings.id #{secondary_sort_direction}")
  end

  def csv_value_for(reading, column)
    case column
    when "recorded_at" then reading.recorded_at&.utc&.iso8601
    when "zone" then reading.zone&.name.presence || reading.zone&.zone_id
    when "node" then reading.node_id
    when "moisture_percent" then reading.moisture_percent
    when "moisture_raw" then reading.moisture_raw
    when "soil_temp_c" then reading.soil_temp_c
    when "battery_percent" then reading.battery_percent
    when "health" then reading.health
    when "last_error" then reading.last_error.presence || "none"
    when "publish_reason" then reading.publish_reason
    end
  end

end
