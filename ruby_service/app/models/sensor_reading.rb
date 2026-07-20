class SensorReading < ApplicationRecord
  belongs_to :zone

  validates :node_id, presence: true
  validates :recorded_at, presence: true
  validates :moisture_raw, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :moisture_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :soil_temp_c, numericality: true, allow_nil: true
  validates :battery_voltage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :battery_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :wifi_rssi, numericality: { greater_than_or_equal_to: -130, less_than_or_equal_to: 0 }, allow_nil: true
  validates :uptime_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :wake_count, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :air_temperature_c, numericality: { greater_than_or_equal_to: -40, less_than_or_equal_to: 125 }, allow_nil: true
  validates :humidity_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :greenhouse_alert_status, inclusion: { in: %w[normal warning critical] }

  def air_temperature_f
    return if air_temperature_c.nil?

    (air_temperature_c.to_f * 9.0 / 5.0) + 32.0
  end

  # Human-friendly value for a sortable-table column, with "—" placeholders for
  # nil. `nodes_by_node_id` (node_id => Node) is used to resolve a friendly
  # display name for the "node" column when the caller has one preloaded.
  def display_value(column, nodes_by_node_id: {})
    case column
    when "recorded_at" then recorded_at.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
    when "zone" then zone&.name.presence || zone&.zone_id || "—"
    when "node" then nodes_by_node_id[node_id]&.display_name || node_id
    when "moisture_percent" then moisture_percent.present? ? "#{moisture_percent}%" : "—"
    when "moisture_raw" then moisture_raw || "—"
    when "air_temperature_f" then air_temperature_f.present? ? "#{air_temperature_f.round(1)} F" : "—"
    when "humidity_percent" then humidity_percent.present? ? "#{humidity_percent}%" : "—"
    when "greenhouse_alert_status" then greenhouse_alert_status.presence&.titleize || "—"
    when "health" then health || "—"
    when "last_error" then last_error.presence || "none"
    when "publish_reason" then publish_reason || "—"
    when "wifi_rssi" then wifi_rssi || "—"
    when "wake_count" then wake_count || "—"
    when "uptime_seconds" then uptime_seconds || "—"
    else "—"
    end
  end

  # Raw/parseable value for CSV export (no unit suffixes or "—" placeholders).
  def csv_value(column)
    case column
    when "recorded_at" then recorded_at&.utc&.iso8601
    when "zone" then zone&.name.presence || zone&.zone_id
    when "node" then node_id
    when "moisture_percent" then moisture_percent
    when "moisture_raw" then moisture_raw
    when "air_temperature_f" then air_temperature_f&.round(1)
    when "humidity_percent" then humidity_percent
    when "greenhouse_alert_status" then greenhouse_alert_status
    when "health" then health
    when "last_error" then last_error.presence || "none"
    when "publish_reason" then publish_reason
    when "wifi_rssi" then wifi_rssi
    when "wake_count" then wake_count
    when "uptime_seconds" then uptime_seconds
    end
  end
end
