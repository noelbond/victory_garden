class SetupWateringTargetAuthority
  Target = Struct.new(:kind, :identifier, :irrigation_line, keyword_init: true)
  Result = Struct.new(
    :ready,
    :reason,
    :actuator,
    :targets,
    :required_target_count,
    :mapped_target_count,
    :referenced_output_indexes,
    :missing_targets,
    :invalid_targets,
    keyword_init: true
  ) do
    def ready?
      ready
    end
  end

  def self.call
    new.call
  end

  def initialize(actuator = ActuatorDevice.current_device)
    @actuator = actuator
  end

  def call
    return result(false, "no_current_actuator") if actuator.blank?
    return result(false, "actuator_not_ready") unless actuator_ready?
    return result(false, "no_watering_targets") if targets.empty?

    invalid = targets.select { |target| invalid_irrigation_line?(target.irrigation_line) }
    missing = targets.reject { |target| invalid.include?(target) || output_for(target).present? }
    invalid_outputs = targets.select { |target| output_for(target).present? && !ready_output?(output_for(target)) }

    return result(false, "invalid_mapping", invalid_targets: invalid) if invalid.any?
    return result(false, "missing_output", missing_targets: missing) if missing.any?
    return result(false, "output_not_ready", invalid_targets: invalid_outputs) if invalid_outputs.any?

    result(true, nil)
  end

  private

  attr_reader :actuator

  def actuator_ready?
    SetupActuatorAuthority.new(actuator).bootstrap_payload.fetch(:complete)
  end

  def targets
    @targets ||= zone_targets + node_targets
  end

  def zone_targets
    Zone.where(active: true).where.not(irrigation_line: nil).order(:zone_id).map do |zone|
      Target.new(kind: "zone", identifier: zone.zone_id, irrigation_line: zone.irrigation_line)
    end
  end

  def node_targets
    Node.assigned.includes(:crop_profile, zone: :crop_profile).order(:node_id).filter_map do |node|
      next if node.zone.blank? || !node.zone.active?
      next if node.effective_crop_profile.blank?

      Target.new(
        kind: "node",
        identifier: node.node_id,
        irrigation_line: node.irrigation_line || node.zone.irrigation_line
      )
    end
  end

  def output_for(target)
    return if actuator.blank?
    return if target.irrigation_line.blank?

    outputs_by_index[target.irrigation_line]
  end

  def invalid_irrigation_line?(line)
    return false if line.blank?
    return true unless line.is_a?(Integer)
    return true unless line.positive?

    line > actuator.irrigation_line_count
  end

  def ready_output?(output)
    SetupActuatorAuthority::READY_OUTPUT_STATES.include?(output.state)
  end

  def outputs_by_index
    @outputs_by_index ||= actuator.actuator_outputs.index_by(&:output_index)
  end

  def result(ready, reason, missing_targets: [], invalid_targets: [])
    Result.new(
      ready: ready,
      reason: reason,
      actuator: actuator,
      targets: targets,
      required_target_count: targets.size,
      mapped_target_count: mapped_target_count,
      referenced_output_indexes: targets.map(&:irrigation_line).compact.uniq.sort,
      missing_targets: missing_targets,
      invalid_targets: invalid_targets
    )
  end

  def mapped_target_count
    return 0 if actuator.blank?

    targets.count { |target| output_for(target).present? }
  end
end
