class ConnectionSetting < ApplicationRecord
  HOST_PATTERN = /\A(?:localhost|(?:\[[0-9A-Fa-f:]+\])|(?:\d{1,3}\.){3}\d{1,3}|[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*)\z/

  encrypts :mqtt_password

  validates :mqtt_port, numericality: { greater_than: 0, less_than_or_equal_to: 65_535, only_integer: true }, allow_nil: true
  validates :irrigation_line_count, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :mqtt_host, format: { with: HOST_PATTERN, message: "must be a valid hostname, IPv4 address, or bracketed IPv6 address" }, allow_blank: true

  validate :irrigation_line_count_covers_assigned_zones

  after_commit :enqueue_config_publish_if_irrigation_changed, on: %i[create update]

  private

  def irrigation_line_count_covers_assigned_zones
    return if irrigation_line_count.blank?

    overflow = Zone.where("irrigation_line > ?", irrigation_line_count).order(:irrigation_line).first
    return unless overflow

    errors.add(:irrigation_line_count, "must be at least #{overflow.irrigation_line} to keep existing zone assignments")
  end

  def enqueue_config_publish_if_irrigation_changed
    return unless saved_change_to_irrigation_line_count?

    ConfigPublishJob.perform_later
  end
end
