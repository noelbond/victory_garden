class ActuatorDevice < ApplicationRecord
  STATES = %w[pending_observation observed configured ready stale conflict inactive].freeze
  FIRMWARE_KIND = "actuator"
  CONFIG_STATUSES = %w[pending applied error].freeze
  CURRENT_SUPERSESSION_REASON = "replacement_provisioning"

  has_many :actuator_outputs, dependent: :destroy

  validates :logical_node_id, presence: true
  validates :firmware_kind, presence: true, inclusion: { in: [FIRMWARE_KIND] }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :config_status, inclusion: { in: CONFIG_STATUSES }, allow_nil: true
  validates :irrigation_line_count, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :logical_node_id, uniqueness: { conditions: -> { where(current: true) } }, if: :current?
  validates :device_uid, uniqueness: true, allow_nil: true

  validate :current_record_is_not_superseded

  scope :current, -> { where(current: true) }

  def self.current_device(lock: false)
    scope = current.includes(:actuator_outputs)
    scope = scope.lock if lock
    scope.first
  end

  def superseded?
    superseded_at.present? || !current?
  end

  def output_inventory_complete?
    return false if irrigation_line_count.blank? || irrigation_line_count <= 0

    actuator_outputs.map(&:output_index).sort == expected_output_indexes
  end

  def output_inventory_ready?
    output_inventory_complete? &&
      actuator_outputs.all? { |output| SetupActuatorAuthority::READY_OUTPUT_STATES.include?(output.state) }
  end

  def expected_output_indexes
    return [] if irrigation_line_count.blank? || irrigation_line_count <= 0

    (1..irrigation_line_count).to_a
  end

  def reconcile_expected_outputs!(default_state: "available")
    expected_output_indexes.each do |index|
      actuator_outputs.find_or_create_by!(output_index: index) do |output|
        output.state = default_state
      end
    end
  end

  def supersede_for_replacement!(at: Time.current)
    update!(
      current: false,
      state: "inactive",
      superseded_at: at,
      supersession_reason: CURRENT_SUPERSESSION_REASON
    )
  end

  private

  def current_record_is_not_superseded
    errors.add(:current, "actuator cannot be current after supersession") if current? && superseded_at.present?
  end
end
