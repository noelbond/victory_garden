class Node < ApplicationRecord
  # Must match firmware VG_ADS1115_CHANNEL_COUNT (and the desktop installer's
  # EXPECTED_SENSOR_CHANNEL_COUNT) for devices that report a device_id.
  EXPECTED_CHANNELS_PER_DEVICE = 4
  COMMUNICATION_TRANSPORTS = %w[wifi lora auto].freeze

  belongs_to :zone
  belongs_to :crop_profile, optional: true

  before_destroy :prevent_bound_package_node_destruction
  after_commit :enqueue_config_publish_if_zone_changed, on: :update
  after_commit :enqueue_config_publish_if_watering_assignment_changed, on: :update
  after_commit :enqueue_node_config_publish_if_calibration_changed, on: :update
  after_commit :enqueue_config_publish_if_destroyed_assigned, on: :destroy

  validates :node_id, presence: true, uniqueness: true
  validates :name, length: { maximum: 100 }, allow_nil: true
  validates :irrigation_line, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :irrigation_line, uniqueness: true, allow_nil: true
  validates :battery_voltage, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }, allow_nil: true
  validates :wifi_rssi, numericality: { greater_than_or_equal_to: -130, less_than_or_equal_to: 0 }, allow_nil: true
  validates :active, inclusion: { in: [true, false] }
  validates :communication_transport, presence: true, inclusion: { in: COMMUNICATION_TRANSPORTS }
  validates :config_status, inclusion: { in: %w[pending applied error unassigned], allow_nil: true }
  validates :moisture_raw_dry, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validates :moisture_raw_wet, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_nil: true
  validate :moisture_calibration_is_valid
  validate :firmware_visible_identities_are_valid
  validate :device_package_zone_is_consistent
  validate :bound_package_topology_is_not_mutated_directly

  scope :assigned, -> { all }

  def self.group_by_device(nodes)
    nodes.to_a.group_by { |node| node.device_id.presence || "node:#{node.id}" }
  end

  def self.canonical_package_node_ids(package_id)
    EXPECTED_CHANNELS_PER_DEVICE.times.map { |channel| "#{package_id}-ch#{channel}" }
  end

  def device_siblings
    return self.class.where(id: id) if device_id.blank?

    self.class.where(device_id: device_id)
  end

  def assigned?
    zone_id.present?
  end

  def display_name
    return name if name.present?

    channel = channel_index
    return node_id unless zone.present? && channel&.between?(0, EXPECTED_CHANNELS_PER_DEVICE - 1)

    "#{zone.name.presence || zone.zone_id} Node #{channel + 1}"
  end

  def channel_index
    match = node_id.to_s.match(/(?:^|-)ch(\d+)\z/)
    return nil unless match

    match[1].to_i
  end

  def calibration_configured?
    moisture_raw_dry.present? && moisture_raw_wet.present?
  end

  def watering_configured?
    active? && zone&.active? && crop_profile.present? && irrigation_line.present?
  end

  def irrigation_line_supported?(installed_capacity: ConnectionSetting.first&.irrigation_line_count)
    irrigation_line.present? && installed_capacity.to_i.positive? && irrigation_line <= installed_capacity
  end

  def expected_publish_interval_seconds
    zone&.expected_publish_interval_seconds || [Zone::DEFAULT_PUBLISH_INTERVAL_MS / 1000.0, 1.0].max
  end

  def offline?
    Zone.freshness_for(last_seen_at, expected_publish_interval_seconds) == "offline"
  end

  def latest_sensor_reading
    SensorReading.where(node_id: node_id).order(recorded_at: :desc).first
  end

  def wifi_transport?
    communication_transport == "wifi"
  end

  def lora_transport?
    communication_transport == "lora"
  end

  def auto_transport?
    communication_transport == "auto"
  end

  def next_expected_wake_at(reference_time: Time.current)
    # Rails does not persist whether this device uses interval or fixed-hour schedule mode.
    nil
  end

  private

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
    return unless saved_change_to_crop_profile_id? || saved_change_to_irrigation_line?

    ConfigPublishJob.perform_later
    PublishNodeConfigJob.perform_later(id) if assigned? && (saved_change_to_crop_profile_id? || saved_change_to_irrigation_line?)
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

  def firmware_visible_identities_are_valid
    validate_firmware_identity(:node_id) do
      SensorIdentityContract.validate_node_id!(node_id)
    end if node_id.present?

    validate_firmware_identity(:device_id) do
      SensorIdentityContract.validate_package_id!(device_id)
    end if device_id.present?
  end

  def validate_firmware_identity(attribute)
    yield
  rescue SensorIdentityContract::InvalidIdentity => error
    errors.add(attribute, error.message)
  end

  def device_package_zone_is_consistent
    return if device_id.blank? || zone_id.blank?

    sibling_zone_ids = self.class.where(device_id: device_id).where.not(id: id).distinct.pluck(:zone_id)
    if sibling_zone_ids.any? { |sibling_zone_id| sibling_zone_id != zone_id }
      errors.add(:zone, "must match every channel in sensor package #{device_id}")
    end

    other_package_node = self.class.where(zone_id: zone_id).where.not(id: id).where.not(device_id: [nil, device_id]).first
    if other_package_node
      errors.add(:zone, "already owns sensor package #{other_package_node.device_id}")
    end

    zone_binding = bound_sensor_package_id
    return if zone_binding.blank? || zone_binding == device_id

    errors.add(:zone, "is bound to sensor package #{zone_binding}")
  end

  def bound_package_topology_is_not_mutated_directly
    bound_package = bound_sensor_package_id
    return if bound_package.blank? || Zone.sensor_package_mutation?
    return unless new_record? || will_save_change_to_zone_id? || will_save_change_to_node_id? || will_save_change_to_device_id?

    errors.add(:base, "canonical Nodes in a bound sensor package can only be changed by package provisioning")
  end

  def prevent_bound_package_node_destruction
    return unless bound_sensor_package_id.present?
    return if Zone.sensor_package_mutation?

    raise ActiveRecord::RecordNotDestroyed.new("cannot delete a Node from a bound sensor package", self)
  end

  def bound_sensor_package_id
    return if zone_id.blank?

    Zone.where(id: zone_id).pick(:sensor_device_id)
  end

end
