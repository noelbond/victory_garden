require "csv"

class WateringEventsController < ApplicationController
  include HistoryFiltering

  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 250
  PER_PAGE_OPTIONS = [25, 50, 100, 250].freeze
  DEFAULT_TIMEFRAME = "last_7d"
  TIMEFRAME_OPTIONS = {
    "last_24h" => "Last 24 Hours",
    "last_7d" => "Last 7 Days",
    "last_30d" => "Last 30 Days",
    "last_90d" => "Last 90 Days",
    "ytd" => "Year to Date",
    "custom" => "Custom Range"
  }.freeze
  FILTER_PRESETS = [
    {label: "Last 24 Hours", params: {timeframe: "last_24h"}},
    {label: "Completed", params: {timeframe: "last_7d", status: "completed"}},
    {label: "Faults", params: {timeframe: "last_30d", status: "fault"}},
    {label: "Manual", params: {timeframe: "last_30d", reason: "manual_trigger"}},
    {label: "Long Runtime", params: {timeframe: "last_30d", runtime_min: "30"}}
  ].freeze
  SORTABLE_COLUMNS = {
    "issued_at" => "watering_events.issued_at",
    "zone" => "zones.zone_id",
    "command" => "watering_events.command",
    "runtime_seconds" => "watering_events.runtime_seconds",
    "reason" => "watering_events.reason",
    "status" => "watering_events.status"
  }.freeze
  TABLE_COLUMNS = [
    ["issued_at", "Issued At"],
    ["zone", "Zone"],
    ["command", "Command"],
    ["runtime_seconds", "Runtime (s)"],
    ["reason", "Watering Reason"],
    ["status", "Status"]
  ].freeze
  DEFAULT_COLUMNS = TABLE_COLUMNS.map(&:first).freeze

  def index
    @zones = Zone.order(:zone_id)
    @selected_zone = selected_zone
    @timeframe = selected_timeframe
    @from, @to = resolved_range
    @per_page = resolved_per_page
    @page = [params[:page].to_i, 1].max
    @selected_columns = resolved_columns
    @status_options = WateringEvent.distinct.order(:status).pluck(:status)
    @command_options = WateringEvent.distinct.order(:command).pluck(:command)
    @reason_options = WateringEvent.distinct.order(:reason).pluck(:reason).compact.reject(&:blank?)
    @filter_presets = FILTER_PRESETS
    base_scope = filtered_watering_events_scope

    if request.format.csv?
      watering_events_csv_stream(base_scope)
      return
    end

    @total_events = base_scope.count
    @total_pages = [(@total_events.to_f / @per_page).ceil, 1].max
    @page = [@page, @total_pages].min
    @watering_events = base_scope
      .order(Arel.sql("#{SORTABLE_COLUMNS.fetch(sort_column)} #{sort_direction.upcase}, watering_events.id #{secondary_sort_direction}"))
      .offset((@page - 1) * @per_page)
      .limit(@per_page)

    @active_filter_count = active_filter_count
    @completed_count = base_scope.where(status: "completed").count
    @fault_count = base_scope.where(status: "fault").count
  end

  def watering_events_csv_stream(scope)
    headers["Content-Type"] = "text/csv"
    headers["Content-Disposition"] = "attachment; filename=watering-events-#{Time.current.utc.strftime('%Y%m%d-%H%M%S')}.csv"
    headers["Cache-Control"] = "no-cache"
    columns = table_columns
    self.response_body = Enumerator.new do |yielder|
      yielder << CSV.generate_line(columns.map(&:last))
      scope.find_each(batch_size: 1000) do |event|
        row = columns.map { |col, _label| csv_value_for(event, col) }
        yielder << CSV.generate_line(row)
      end
    end
  end

  private

  def filtered_watering_events_scope
    scope = WateringEvent.includes(:zone).joins(:zone).where(issued_at: @from..@to)
    scope = scope.where(zone: @selected_zone) if @selected_zone
    scope = scope.where(status: params[:status]) if @status_options.include?(params[:status])
    scope = scope.where(command: params[:command]) if @command_options.include?(params[:command])
    scope = scope.where(reason: params[:reason]) if params[:reason].present?
    scope = scope.where("watering_events.runtime_seconds >= ?", Integer(params[:runtime_min])) if valid_integer_param?(:runtime_min)
    scope = scope.where("watering_events.runtime_seconds <= ?", Integer(params[:runtime_max])) if valid_integer_param?(:runtime_max)
    scope
  end

  def selected_zone
    return if params[:zone_id].blank?

    Zone.find_by(id: params[:zone_id])
  end

  def active_filter_count
    [
      @selected_zone.present?,
      params[:status].present?,
      params[:command].present?,
      params[:reason].present?,
      params[:runtime_min].present?,
      params[:runtime_max].present?,
      @timeframe == "custom"
    ].count(true)
  end

  def watering_events_csv(scope)
    csv_string_for_scope(scope, tie_breaker: "watering_events.id #{secondary_sort_direction}")
  end

  def csv_value_for(event, column)
    case column
    when "issued_at" then event.issued_at&.utc&.iso8601
    when "zone" then event.zone&.name.presence || event.zone&.zone_id
    when "command" then event.command
    when "runtime_seconds" then event.runtime_seconds
    when "reason" then event.reason.presence || "—"
    when "status" then event.status
    end
  end

end
