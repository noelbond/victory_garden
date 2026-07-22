class Node < ApplicationRecord
  # Must match firmware VG_ADS1115_CHANNEL_COUNT (and the desktop installer's
  # EXPECTED_SENSOR_CHANNEL_COUNT) for devices that report a device_id.
  EXPECTED_CHANNELS_PER_DEVICE = 4

  belongs_to :zone, optional: true
  belongs_to :crop_profile, optional: true

  after_commit :enqueue_config_publish_if_zone_changed, on: :update
  after_commit :cascade_zone_to_device_siblings, on: :update
  after_commit :sync_default_name_if_zone_changed, on: :update
  after_commit :enqueue_config_publish_if_watering_assignment_changed, on: :update
  after_commit :enqueue_node_config_publish_if_calibration_changed, on: :update
  after_commit :enqueue_config_publish_if_destroyed_assigned, on: :destroy

  validates :node_id, presence: true, uniqueness: true
  validates :name, length: { maximum: 100 }, allow_nil: true
  validates :irrigation_line, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :irrigation_line, uniqueness: true, allow_nil: true
  validates :battery_voltage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :wifi_rssi, numericality: { greater_than_or_equal_to: -130, less_than_or_equal_to: 0 }, allow_nil: true
  validates :last_seen_at, presence: true
  validates :config_status, inclusion: { in: %w[pending applied error unassigned], allow_nil: true }
  validates :moisture_raw_dry, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validates :moisture_raw_wet, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validate :moisture_calibration_is_valid
  validate :irrigation_line_is_available

  scope :unassigned, -> { where(zone_id: nil) }
  scope :assigned, -> { where.not(zone_id: nil) }

  def self.sync_default_names_for_zone!(zone)
    return if zone.blank?

    label_base = zone.name.presence || zone.zone_id
    grouped = group_by_device(zone.nodes.order(:device_id, :node_id))
    timestamp = Time.current

    grouped.each_value do |device_nodes|
      sorted_nodes = device_nodes.sort_by { |node| [node.channel_index || 999, node.node_id] }
      has_channel_indexes = sorted_nodes.any? { |node| node.channel_index.present? }

      sorted_nodes.each_with_index do |node, index|
        if node.channel_index.nil? && has_channel_indexes
          # A node without a parseable channel index sharing a device_id with
          # real ADS1115 channels is a data anomaly (e.g. a stray/legacy row) -
          # don't fold it into the numbered sequence with a made-up position.
          node.update_columns(name: nil, updated_at: timestamp) if node.name.present?
          next
        end

        channel_number = (node.channel_index || index) + 1
        default_name = "#{label_base}_Ch#{channel_number}"
        next if node.name == default_name
        next if node.name.present? && !node.auto_generated_name?

        node.update_columns(name: default_name, updated_at: timestamp)
      end
    end
  end

  def self.group_by_device(nodes)
    nodes.to_a.group_by { |node| node.device_id.presence || "node:#{node.id}" }
  end

  def device_siblings
    return self.class.where(id: id) if device_id.blank?

    self.class.where(device_id: device_id)
  end

  def assigned?
    zone_id.present?
  end

  def display_name
    name.presence || node_id
  end

  def auto_generated_name?
    name.to_s.match?(/(?:_Ch\d+| node \d+)\z/)
  end

  def channel_index
    match = node_id.to_s.match(/(?:^|-)ch(\d+)\z/)
    return nil unless match

    match[1].to_i
  end

  def calibration_configured?
    moisture_raw_dry.present? && moisture_raw_wet.present?
  end

  def effective_crop_profile
    crop_profile || zone&.crop_profile
  end

  def watering_configured?
    zone.present? && effective_crop_profile.present? && irrigation_line.present?
  end

  def expected_publish_interval_seconds
    zone&.expected_publish_interval_seconds || [Zone::DEFAULT_PUBLISH_INTERVAL_MS / 1000.0, 1.0].max
  end

  def latest_sensor_reading
    SensorReading.where(node_id: node_id).order(recorded_at: :desc).first
  end

  def next_expected_wake_at(reference_time: Time.current)
    # Rails does not persist whether this device uses interval or fixed-hour schedule mode.
    nil
  end

  private

  def cascade_zone_to_device_siblings
    return unless saved_change_to_zone_id?
    return if device_id.blank?

    updates = {
      zone_id: zone_id,
      updated_at: Time.current
    }
    updates[:name] = nil if zone_id.blank?

    device_siblings.where.not(id: id).update_all(updates)
  end

  def sync_default_name_if_zone_changed
    return unless saved_change_to_zone_id?

    if zone.present?
      self.class.sync_default_names_for_zone!(zone)
    elsif name.present?
      update_columns(name: nil, updated_at: Time.current)
    end
  end

  def enqueue_config_publish_if_zone_changed
    return unless saved_change_to_zone_id?

    ConfigPublishJob.perform_later
  end

  def enqueue_config_publish_if_destroyed_assigned
    return if zone_id.blank?

    ConfigPublishJob.perform_later
  end

  def enqueue_node_config_publish_if_calibration_changed
    return unless assigned?
    return unless saved_change_to_moisture_raw_dry? || saved_change_to_moisture_raw_wet?

    PublishNodeConfigJob.perform_later(id)
  end

  def enqueue_config_publish_if_watering_assignment_changed
    return unless saved_change_to_crop_profile_id? || saved_change_to_irrigation_line? || saved_change_to_name?

    ConfigPublishJob.perform_later
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

  def irrigation_line_is_available
    return if irrigation_line.blank?

    setting = ConnectionSetting.first
    return if setting.blank? || setting.irrigation_line_count.blank?
    return if irrigation_line <= setting.irrigation_line_count

    errors.add(:irrigation_line, "must be between 1 and #{setting.irrigation_line_count}")
  end
end
