class Node < ApplicationRecord
  belongs_to :zone, optional: true

  validates :node_id, presence: true, uniqueness: true
  validates :battery_voltage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :wifi_rssi, numericality: { greater_than_or_equal_to: -130, less_than_or_equal_to: 0 }, allow_nil: true
  validates :last_seen_at, presence: true
  validates :config_status, inclusion: { in: %w[pending applied error unassigned], allow_nil: true }

  scope :unclaimed, -> { where(zone_id: nil) }
  scope :claimed, -> { where.not(zone_id: nil) }

  def claimed?
    zone_id.present?
  end
end
