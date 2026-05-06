class Node < ApplicationRecord
  belongs_to :zone, optional: true

  after_commit :enqueue_config_publish_if_zone_changed, on: :update
  after_commit :enqueue_node_config_publish_if_calibration_changed, on: :update
  after_commit :enqueue_config_publish_if_destroyed_claimed, on: :destroy

  validates :node_id, presence: true, uniqueness: true
  validates :battery_voltage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :wifi_rssi, numericality: { greater_than_or_equal_to: -130, less_than_or_equal_to: 0 }, allow_nil: true
  validates :last_seen_at, presence: true
  validates :config_status, inclusion: { in: %w[pending applied error unassigned], allow_nil: true }
  validates :moisture_raw_dry, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validates :moisture_raw_wet, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validate :moisture_calibration_is_valid

  scope :unclaimed, -> { where(zone_id: nil) }
  scope :claimed, -> { where.not(zone_id: nil) }

  def claimed?
    zone_id.present?
  end

  def calibration_configured?
    moisture_raw_dry.present? && moisture_raw_wet.present?
  end

  private

  def enqueue_config_publish_if_zone_changed
    return unless saved_change_to_zone_id?

    ConfigPublishJob.perform_later
  end

  def enqueue_config_publish_if_destroyed_claimed
    return if zone_id.blank?

    ConfigPublishJob.perform_later
  end

  def enqueue_node_config_publish_if_calibration_changed
    return unless claimed?
    return unless saved_change_to_moisture_raw_dry? || saved_change_to_moisture_raw_wet?

    PublishNodeConfigJob.perform_later(id)
  end

  def moisture_calibration_is_valid
    return if moisture_raw_dry.blank? && moisture_raw_wet.blank?

    if moisture_raw_dry.blank? || moisture_raw_wet.blank?
      errors.add(:base, "moisture calibration requires both dry and wet raw values")
      return
    end

    return unless moisture_raw_dry == moisture_raw_wet

    errors.add(:base, "moisture calibration dry and wet raw values cannot be the same")
  end
end
