class Zone < ApplicationRecord
  DEFAULT_ALLOWED_HOURS = {
    "start_hour" => 6,
    "end_hour" => 20
  }.freeze
  DEFAULT_PUBLISH_INTERVAL_MS = 3_600_000

  belongs_to :crop_profile
  has_many :nodes, dependent: :nullify
  has_many :sensor_readings, dependent: :destroy
  has_many :watering_events, dependent: :destroy
  has_many :actuator_statuses, dependent: :destroy
  has_many :faults, dependent: :destroy

  before_validation :ensure_ids
  before_validation :apply_default_allowed_hours
  before_validation :apply_default_publish_interval
  before_validation :normalize_allowed_hours
  before_validation :normalize_irrigation_line
  validate :allowed_hours_are_valid
  validate :irrigation_line_is_valid
  validates :publish_interval_ms, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  after_commit :enqueue_config_publish, on: :create
  after_commit :enqueue_config_publish_if_relevant_update, on: :update
  after_commit :enqueue_node_config_publish_if_relevant_update, on: :update
  after_commit :sync_node_names_if_label_changed, on: :update
  after_commit :enqueue_config_publish, on: :destroy

  validates :zone_id, presence: true, uniqueness: true
  validates :name, length: { maximum: 100 }, allow_nil: true
  validates :irrigation_line, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :irrigation_line, uniqueness: true, allow_nil: true

  def reading_frequency_hours
    return nil if publish_interval_ms.blank?

    publish_interval_ms / 3_600_000
  end

  def expected_publish_interval_seconds
    [(publish_interval_ms.presence || DEFAULT_PUBLISH_INTERVAL_MS).to_i / 1000.0, 1.0].max
  end

  def reading_freshness(recorded_at)
    self.class.freshness_for(recorded_at, expected_publish_interval_seconds)
  end

  # ok: within one expected interval. stale: within two. offline: beyond that (or never recorded).
  def self.freshness_for(recorded_at, interval_seconds)
    return "offline" if recorded_at.blank?

    age = Time.current - recorded_at

    return "ok" if age <= interval_seconds
    return "stale" if age <= interval_seconds * 2

    "offline"
  end

  private

  def ensure_ids
    self.zone_id = "zone-#{SecureRandom.hex(3)}" if zone_id.blank?
  end

  def apply_default_allowed_hours
    self.allowed_hours = DEFAULT_ALLOWED_HOURS if allowed_hours.nil?
  end

  def apply_default_publish_interval
    self.publish_interval_ms = DEFAULT_PUBLISH_INTERVAL_MS if publish_interval_ms.nil?
  end

  def normalize_allowed_hours
    return if allowed_hours.nil?

    values =
      case allowed_hours
      when ActionController::Parameters
        allowed_hours.to_unsafe_h
      when Hash
        allowed_hours
      else
        return
      end

    normalized = values.stringify_keys.slice("start_hour", "end_hour")
    %w[start_hour end_hour].each do |key|
      value = normalized[key]
      normalized[key] = value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)
    end

    self.allowed_hours = normalized
  end

  def normalize_irrigation_line
    return if irrigation_line.nil?

    self.irrigation_line = irrigation_line.to_i if irrigation_line.is_a?(String) && irrigation_line.match?(/\A\d+\z/)
    self.irrigation_line = nil if irrigation_line == ""
  end

  def allowed_hours_are_valid
    return if allowed_hours.nil?

    unless allowed_hours.is_a?(Hash)
      errors.add(:allowed_hours, "must be a hash")
      return
    end

    values = allowed_hours.stringify_keys
    start_hour = values["start_hour"]
    end_hour = values["end_hour"]

    if start_hour.nil? || end_hour.nil?
      errors.add(:allowed_hours, "must include start_hour and end_hour")
      return
    end

    {
      start_hour: start_hour,
      end_hour: end_hour
    }.each do |key, value|
      unless value.is_a?(Integer) && value.between?(0, 23)
        errors.add(:allowed_hours, "#{key} must be an integer between 0 and 23")
      end
    end

    return unless start_hour.is_a?(Integer) && end_hour.is_a?(Integer)
    return unless start_hour == end_hour

    errors.add(:allowed_hours, "start_hour and end_hour cannot be the same")
  end

  def irrigation_line_is_valid
    return if irrigation_line.nil?

    unless irrigation_line.is_a?(Integer) && irrigation_line.positive?
      errors.add(:irrigation_line, "must be an integer greater than 0")
      return
    end

    setting = ConnectionSetting.first
    return if setting.blank? || setting.irrigation_line_count.blank?
    return if irrigation_line <= setting.irrigation_line_count

    errors.add(:irrigation_line, "must be between 1 and #{setting.irrigation_line_count}")
  end

  def enqueue_config_publish_if_relevant_update
    return unless saved_change_to_zone_id? ||
                  saved_change_to_crop_profile_id? ||
                  saved_change_to_active? ||
                  saved_change_to_publish_interval_ms? ||
                  saved_change_to_allowed_hours? ||
                  saved_change_to_irrigation_line?

    enqueue_config_publish
  end

  def enqueue_node_config_publish_if_relevant_update
    return unless saved_change_to_zone_id? ||
                  saved_change_to_crop_profile_id? ||
                  saved_change_to_active? ||
                  saved_change_to_publish_interval_ms? ||
                  saved_change_to_allowed_hours? ||
                  saved_change_to_irrigation_line?

    Node.group_by_device(nodes).each_value do |device_nodes|
      PublishNodeConfigJob.perform_later(device_nodes.first.id)
    end
  end

  def enqueue_config_publish
    ConfigPublishJob.perform_later
  end

  def sync_node_names_if_label_changed
    return unless saved_change_to_name? || saved_change_to_zone_id?

    Node.sync_default_names_for_zone!(self)
  end
end
