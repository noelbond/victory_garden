require "digest"

class WateringEvent < ApplicationRecord
  STATUSES = %w[queued command_sent acknowledged running completed stopped fault timeout unknown].freeze
  TERMINAL_STATUSES = %w[completed stopped fault timeout unknown].freeze
  ACTIVE_START_STATUSES = %w[queued command_sent acknowledged running].freeze
  ACTIVE_GUARD_LOOKBACK = 15.minutes
  SETUP_TARGET_KINDS = %w[zone node].freeze
  SETUP_IN_PROGRESS_STATUSES = %w[queued requested command_sent published acknowledged running].freeze
  SETUP_RECOVERY_STATUSES = %w[stopped fault faulted timeout timed_out unknown].freeze

  belongs_to :zone
  belongs_to :node, primary_key: :node_id, foreign_key: :node_id, optional: true

  validates :command, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :issued_at, presence: true
  validates :idempotency_key, presence: true
  validates :runtime_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :node_id, length: { maximum: 100 }, allow_nil: true
  validates :setup_target_kind, inclusion: { in: SETUP_TARGET_KINDS }, allow_nil: true
  validates :setup_target_fingerprint, presence: true, if: :setup_validation?
  validates :setup_target_node_id, presence: true, if: -> { setup_target_kind == "node" }

  validate :runtime_consistency
  validate :setup_metadata_consistency

  scope :active_start_commands, -> { where(command: "start_watering", status: ACTIVE_START_STATUSES) }
  scope :blocking_start_commands, -> {
    active_start_commands.where("issued_at >= ?", ACTIVE_GUARD_LOOKBACK.ago)
  }
  scope :setup_validations, -> { where(setup_validation: true) }
  scope :current_setup_validation, -> { setup_validations.where(setup_current: true) }

  def self.setup_target_attributes(zone:, node:, runtime_seconds:)
    target_kind = node.present? ? "node" : "zone"
    crop_profile = node&.effective_crop_profile || zone.crop_profile
    irrigation_line = node&.irrigation_line || zone.irrigation_line

    {
      setup_target_kind: target_kind,
      setup_target_zone_external_id: zone.zone_id,
      setup_target_node_id: node&.node_id,
      setup_target_irrigation_line: irrigation_line,
      setup_target_crop_profile_id: crop_profile&.id,
      setup_target_fingerprint: setup_target_fingerprint(
        target_kind: target_kind,
        zone: zone,
        node: node,
        irrigation_line: irrigation_line,
        crop_profile: crop_profile,
        runtime_seconds: runtime_seconds
      )
    }
  end

  def self.setup_target_fingerprint(target_kind:, zone:, node:, irrigation_line:, crop_profile:, runtime_seconds:)
    parts = [
      target_kind,
      zone.id,
      zone.zone_id,
      zone.active?,
      node&.node_id,
      irrigation_line,
      crop_profile&.id,
      runtime_seconds
    ]

    Digest::SHA256.hexdigest(parts.map { |part| part.nil? ? "" : part.to_s }.join("\0"))
  end

  def setup_target_matches?(zone:, node:)
    return false unless setup_validation?
    return false if zone.blank? || zone_id != zone.id
    return false if setup_target_kind == "node" && node.blank?
    return false if setup_target_kind == "zone" && node.present?
    return false if setup_target_node_id.present? && setup_target_node_id != node&.node_id

    current = self.class.setup_target_attributes(
      zone: zone,
      node: node,
      runtime_seconds: runtime_seconds
    )
    current.fetch(:setup_target_fingerprint) == setup_target_fingerprint
  end

  def setup_ready_for?(zone:, node:)
    setup_validation? &&
      setup_current? &&
      command == "start_watering" &&
      status == "completed" &&
      setup_superseded_at.blank? &&
      setup_invalidated_at.blank? &&
      setup_target_matches?(zone: zone, node: node)
  end

  def setup_unresolved?
    SETUP_IN_PROGRESS_STATUSES.include?(status.to_s)
  end

  def setup_terminal?
    setup_lifecycle_state != "in_progress"
  end

  def setup_lifecycle_state
    return "superseded" if setup_superseded_at.present? || !setup_current?
    return "target_changed" if setup_invalidated_at.present?
    return "completed" if status == "completed"
    return "in_progress" if setup_unresolved?
    return "recovery" if SETUP_RECOVERY_STATUSES.include?(status.to_s)

    "recovery"
  end

  def setup_outcome
    return "superseded" if setup_lifecycle_state == "superseded"
    return "target_changed" if setup_lifecycle_state == "target_changed"
    return "success" if status == "completed"
    return "in_progress" if setup_unresolved?
    return "faulted" if %w[fault faulted].include?(status.to_s)
    return "timed_out" if %w[timeout timed_out].include?(status.to_s)
    return status if %w[stopped unknown].include?(status.to_s)

    "unsupported"
  end

  def supersede_setup_validation!(reason: "retry")
    update!(
      setup_current: false,
      setup_superseded_at: Time.current,
      setup_supersession_reason: reason
    )
  end

  def invalidate_setup_validation!(reason:)
    return if setup_invalidated_at.present?

    update!(
      setup_invalidated_at: Time.current,
      setup_invalidation_reason: reason
    )
  end

  private

  def runtime_consistency
    return unless command == "stop_watering" && runtime_seconds.present?

    errors.add(:runtime_seconds, "must be blank for stop_watering")
  end

  def setup_metadata_consistency
    errors.add(:setup_current, "requires setup validation") if setup_current? && !setup_validation?
    return unless setup_validation?

    errors.add(:command, "must be start_watering for setup validation") unless command == "start_watering"
    errors.add(:setup_target_kind, "can't be blank") if setup_target_kind.blank?
  end
end
