class SetupActuatorAuthority
  READY_OUTPUT_STATES = %w[available assigned].freeze
  UNREADY_OUTPUT_STATES = %w[disabled faulted unknown].freeze

  def self.bootstrap_payload
    new(ActuatorDevice.current_device).bootstrap_payload
  end

  def initialize(actuator)
    @actuator = actuator
  end

  def bootstrap_payload
    return none_payload if actuator.blank?

    {
      supported: true,
      authoritative: true,
      state: effective_state,
      persisted_state: actuator.state,
      complete: complete?,
      message: message,
      recovery: recovery,
      recovery_message: recovery_message,
      operator_action_required: !complete?,
      actuator: actuator_payload,
      outputs: output_payloads
    }
  end

  private

  attr_reader :actuator

  def none_payload
    {
      supported: true,
      authoritative: true,
      state: "none",
      complete: false,
      message: "No Rails actuator provisioning record exists yet.",
      recovery: nil,
      recovery_message: "Provision the actuator Pico deliberately when the hardware is ready.",
      operator_action_required: true,
      actuator: nil,
      outputs: []
    }
  end

  def complete?
    readiness_issue.nil?
  end

  def effective_state
    return "inactive" if actuator.superseded?
    return actuator.state unless actuator.state == "ready"

    complete? ? "ready" : "configured"
  end

  def readiness_issue
    return :not_current if !actuator.current? || actuator.superseded_at.present?
    return :not_ready_state unless actuator.state == "ready"
    return :missing_line_count if actuator.irrigation_line_count.blank? || actuator.irrigation_line_count <= 0
    return :incomplete_output_inventory unless output_indexes == expected_output_indexes
    return :unready_output if outputs.any? { |output| UNREADY_OUTPUT_STATES.include?(output.state) }

    nil
  end

  def recovery
    case readiness_issue
    when nil
      nil
    when :missing_line_count
      "missing_irrigation_line_count"
    when :incomplete_output_inventory
      "incomplete_output_inventory"
    when :unready_output
      "output_not_ready"
    when :not_current
      "not_current"
    else
      "not_ready"
    end
  end

  def recovery_message
    {
      "pending_observation" => "Refresh status after the actuator is connected to its hardware. Reprovision only after a deliberate operator choice.",
      "observed" => "Refresh status while Rails waits for configuration acknowledgement. Reprovision the same actuator only by explicit operator action.",
      "configured" => "Refresh status and review actuator output inventory before retrying provisioning.",
      "stale" => "Refresh status first. Reprovision this actuator or replace it only after deliberate operator confirmation.",
      "conflict" => "Review the actuator identity conflict. Refresh, reprovision the intended current actuator, or replace through the provisioning flow.",
      "inactive" => "This actuator is no longer current. Provision a replacement deliberately if this controller should be used for setup."
    }[effective_state]
  end

  def message
    return "Rails confirmed the current actuator provisioning state." if complete?

    {
      "none" => "No Rails actuator provisioning record exists yet.",
      "pending_observation" => "Rails is waiting to observe the actuator after provisioning.",
      "observed" => "Rails has observed the actuator but has not confirmed setup readiness.",
      "configured" => "Rails has actuator configuration evidence, but setup readiness is not complete.",
      "stale" => "The current actuator record has not been observed recently enough to trust for setup.",
      "conflict" => "Rails found a conflicting actuator provisioning identity that requires operator review.",
      "inactive" => "The actuator record is inactive or superseded and cannot complete setup.",
      "ready" => "Rails cannot confirm a complete actuator output inventory."
    }.fetch(actuator.state, "Rails cannot interpret the actuator provisioning state.")
  end

  def actuator_payload
    {
      logical_node_id: actuator.logical_node_id,
      device_uid: actuator.device_uid,
      provisioning_operation_id: actuator.provisioning_operation_id,
      zone_external_id: actuator.zone_external_id,
      board: actuator.board,
      firmware_kind: actuator.firmware_kind,
      firmware_version: actuator.firmware_version,
      irrigation_line_count: actuator.irrigation_line_count,
      provisioned_at: actuator.provisioned_at&.utc&.iso8601,
      last_seen_at: actuator.last_seen_at&.utc&.iso8601,
      config_acknowledged_at: actuator.config_acknowledged_at&.utc&.iso8601,
      config_status: actuator.config_status,
      config_error: actuator.config_error.present? ? "present" : nil,
      current: actuator.current,
      superseded_at: actuator.superseded_at&.utc&.iso8601,
      supersession_reason: actuator.supersession_reason
    }
  end

  def output_payloads
    outputs.map do |output|
      {
        output_index: output.output_index,
        state: output.state
      }
    end
  end

  def outputs
    @outputs ||= actuator.actuator_outputs.sort_by(&:output_index)
  end

  def output_indexes
    outputs.map(&:output_index)
  end

  def expected_output_indexes
    return [] if actuator.irrigation_line_count.blank? || actuator.irrigation_line_count <= 0

    (1..actuator.irrigation_line_count).to_a
  end
end
