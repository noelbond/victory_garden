class ActuatorDevice < ApplicationRecord
  STATES = %w[pending_observation observed configured ready stale conflict inactive].freeze
  FIRMWARE_KIND = "actuator"

  has_many :actuator_outputs, dependent: :destroy

  validates :logical_node_id, presence: true
  validates :firmware_kind, presence: true, inclusion: { in: [FIRMWARE_KIND] }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :irrigation_line_count, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :logical_node_id, uniqueness: { conditions: -> { where(current: true) } }, if: :current?
  validates :device_uid, uniqueness: true, allow_nil: true

  validate :current_record_is_not_superseded

  scope :current, -> { where(current: true) }

  def self.current_device
    current.includes(:actuator_outputs).first
  end

  def superseded?
    superseded_at.present? || !current?
  end

  private

  def current_record_is_not_superseded
    errors.add(:current, "actuator cannot be current after supersession") if current? && superseded_at.present?
  end
end
