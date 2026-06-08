module HistoryFiltering
  extend ActiveSupport::Concern

  included do
    helper_method :sort_column, :sort_direction, :next_sort_direction_for, :table_columns
  end

  private

  def selected_timeframe
    params[:timeframe].presence_in(self.class::TIMEFRAME_OPTIONS.keys) || self.class::DEFAULT_TIMEFRAME
  end

  def resolved_range
    return custom_range if @timeframe == "custom"

    case @timeframe
    when "last_24h"
      [24.hours.ago, Time.current]
    when "last_30d"
      [30.days.ago.beginning_of_day, Time.current]
    when "last_90d"
      [90.days.ago.beginning_of_day, Time.current]
    when "ytd"
      [Time.current.beginning_of_year, Time.current]
    else
      [default_history_window.ago.beginning_of_day, Time.current]
    end
  end

  def custom_range
    from_date = parsed_date_param(:from)&.beginning_of_day || default_history_window.ago.beginning_of_day
    to_date = parsed_date_param(:to)&.end_of_day || Time.current
    from_date <= to_date ? [from_date, to_date] : [to_date.beginning_of_day, from_date.end_of_day]
  end

  def parsed_date_param(key)
    value = params[key].presence
    return if value.blank?

    Date.iso8601(value).in_time_zone
  rescue ArgumentError
    nil
  end

  def resolved_per_page
    requested = params[:per_page].to_i
    return self.class::DEFAULT_PER_PAGE if requested <= 0

    [requested, self.class::MAX_PER_PAGE].min
  end

  def resolved_columns
    requested = Array(params[:columns]).map(&:to_s) & self.class::DEFAULT_COLUMNS
    requested.presence || self.class::DEFAULT_COLUMNS
  end

  def sort_column
    params[:sort].presence_in(self.class::SORTABLE_COLUMNS.keys) || self.class::SORTABLE_COLUMNS.keys.first
  end

  def sort_direction
    params[:direction].presence_in(%w[asc desc]) || "desc"
  end

  def next_sort_direction_for(column)
    sort_column == column && sort_direction == "asc" ? "desc" : "asc"
  end

  def secondary_sort_direction
    sort_direction == "asc" ? "ASC" : "DESC"
  end

  def table_columns
    self.class::TABLE_COLUMNS.select { |column, _label| @selected_columns.include?(column) }
  end

  def valid_float_param?(key)
    value = params[key].presence
    return false if value.blank?

    Float(value)
    true
  rescue ArgumentError, TypeError
    false
  end

  def valid_integer_param?(key)
    value = params[key].presence
    return false if value.blank?

    Integer(value)
    true
  rescue ArgumentError, TypeError
    false
  end

  def apply_freshness_filter(scope)
    return scope unless params[:freshness].present?

    matching_ids = scope.select { |reading| freshness_matches?(reading, params[:freshness]) }.map(&:id)
    return scope.none if matching_ids.empty?

    scope.where(id: matching_ids)
  end

  def freshness_matches?(reading, requested_state)
    state = freshness_state_for(reading)
    case requested_state
    when "stale_or_offline"
      %w[stale offline].include?(state)
    else
      state == requested_state
    end
  end

  def freshness_state_for(reading)
    age = Time.current - reading.recorded_at
    interval_seconds = freshness_interval_seconds_for(reading)

    return "ok" if age <= interval_seconds
    return "stale" if age <= interval_seconds * 2

    "offline"
  end

  def freshness_interval_seconds_for(reading)
    [(reading.zone&.publish_interval_ms.presence || Zone::DEFAULT_PUBLISH_INTERVAL_MS).to_i / 1000.0, 1.0].max
  end

  def csv_string_for_scope(scope, tie_breaker:, trailing_newline: false)
    ordered_scope = scope.order(Arel.sql("#{self.class::SORTABLE_COLUMNS.fetch(sort_column)} #{sort_direction.upcase}, #{tie_breaker}"))

    rows = []
    rows << table_columns.map(&:last)
    ordered_scope.each do |record|
      rows << table_columns.map { |column, _label| csv_value_for(record, column) }
    end

    csv = rows.map { |row| row.map { |value| csv_escape(value) }.join(",") }.join("\n")
    trailing_newline ? "#{csv}\n" : csv
  end

  def csv_escape(value)
    string = value.to_s
    return string unless string.match?(/[",\n]/)

    %("#{string.gsub('"', '""')}")
  end

  def default_history_window
    self.class.const_defined?(:DEFAULT_HISTORY_WINDOW) ? self.class::DEFAULT_HISTORY_WINDOW : 7.days
  end
end
