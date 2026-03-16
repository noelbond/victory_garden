class SensorReading < ApplicationRecord
  belongs_to :zone

  validates :node_id, presence: true
  validates :recorded_at, presence: true
  validates :moisture_raw, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :moisture_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :soil_temp_c, numericality: true, allow_nil: true
  validates :battery_voltage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :battery_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :wifi_rssi, numericality: { greater_than_or_equal_to: -130, less_than_or_equal_to: 0 }, allow_nil: true
  validates :uptime_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :wake_count, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
end
