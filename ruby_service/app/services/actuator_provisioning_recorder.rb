class ActuatorProvisioningRecorder
  Result = Struct.new(:success, :status, :errors, :actuator, keyword_init: true) do
    def success?
      success
    end
  end

  MAX_TEXT_LENGTH = 100
  MAX_ERROR_TEXT_LENGTH = 300
  IDENTIFIER_PATTERN = /\A[a-zA-Z0-9._:-]+\z/

  def self.call(params)
    new(params).call
  end

  def initialize(params)
    @params = params
  end

  def call
    validation_errors = validate
    return failure(:unprocessable_entity, validation_errors) if validation_errors.any?

    ActuatorDevice.transaction do
      op_match = provisioning_operation_id.present? ? ActuatorDevice.find_by(provisioning_operation_id: provisioning_operation_id) : nil
      current = ActuatorDevice.current_device(lock: true)

      if op_match.present?
        return existing_operation_result(op_match, current) if same_identity?(op_match)

        return failure(:conflict, ["Provisioning operation id is already associated with another actuator."])
      end

      if current.present? && current.logical_node_id != logical_node_id
        current.supersede_for_replacement!(at: timestamp)
        current = nil
      end

      if current.present?
        return failure(:conflict, ["Irrigation line count would invalidate existing watering assignments."]) if shrink_conflicts?(current)

        current.update!(actuator_attributes)
        current.reconcile_expected_outputs!
        return success(current.reload)
      end

      actuator = ActuatorDevice.create!(actuator_attributes.merge(current: true))
      actuator.reconcile_expected_outputs!
      success(actuator.reload)
    end
  rescue ActiveRecord::RecordNotUnique
    failure(:conflict, ["Another actuator provisioning attempt was recorded first. Refresh setup state and retry deliberately."])
  end

  private

  attr_reader :params

  def existing_operation_result(actuator, current)
    unless actuator.current?
      return failure(:conflict, ["Provisioning operation id belongs to a non-current actuator."])
    end

    if current.present? && current.id != actuator.id
      return failure(:conflict, ["Provisioning operation id belongs to a non-current actuator."])
    end

    actuator.reconcile_expected_outputs!
    success(actuator.reload)
  end

  def actuator_attributes
    {
      logical_node_id: logical_node_id,
      provisioning_operation_id: provisioning_operation_id,
      zone_external_id: zone_external_id,
      board: board,
      firmware_kind: ActuatorDevice::FIRMWARE_KIND,
      irrigation_line_count: irrigation_line_count,
      state: "pending_observation",
      provisioned_at: timestamp,
      last_seen_at: nil,
      config_acknowledged_at: nil,
      config_status: "pending",
      config_error: nil
    }
  end

  def validate
    errors = []
    errors << "Actuator logical node id is required." if logical_node_id.blank?
    errors << "Actuator logical node id is invalid." if invalid_identifier?(logical_node_id)
    errors << "Provisioning operation id is required." if provisioning_operation_id.blank?
    errors << "Provisioning operation id is invalid." if invalid_identifier?(provisioning_operation_id)
    errors << "Zone id is invalid." if invalid_optional_identifier?(zone_external_id)
    errors << "Board name is invalid." if board.present? && (board.length > MAX_TEXT_LENGTH || board.include?("\u0000"))
    errors << "Connection settings must define a positive irrigation line count before actuator provisioning." if irrigation_line_count.blank?
    errors
  end

  def invalid_identifier?(value)
    value.present? && (value.length > MAX_TEXT_LENGTH || !value.match?(IDENTIFIER_PATTERN))
  end

  def invalid_optional_identifier?(value)
    value.present? && invalid_identifier?(value)
  end

  def same_identity?(actuator)
    actuator.logical_node_id == logical_node_id &&
      actuator.zone_external_id.to_s == zone_external_id.to_s &&
      actuator.board.to_s == board.to_s
  end

  def shrink_conflicts?(actuator)
    return false if actuator.irrigation_line_count.blank?
    return false if irrigation_line_count >= actuator.irrigation_line_count

    out_of_range = actuator.actuator_outputs.where("output_index > ?", irrigation_line_count).pluck(:output_index)
    return false if out_of_range.empty?

    Node.where(irrigation_line: out_of_range).exists? || Zone.where(irrigation_line: out_of_range).exists?
  end

  def logical_node_id
    @logical_node_id ||= normalized_string(params[:logical_node_id])
  end

  def provisioning_operation_id
    @provisioning_operation_id ||= normalized_string(params[:provisioning_operation_id])
  end

  def zone_external_id
    @zone_external_id ||= normalized_string(params[:zone_external_id])
  end

  def board
    @board ||= normalized_string(params[:board])
  end

  def irrigation_line_count
    @irrigation_line_count ||= begin
      value = ConnectionSetting.first&.irrigation_line_count
      value.present? && value.to_i.positive? ? value.to_i : nil
    end
  end

  def timestamp
    @timestamp ||= Time.current
  end

  def normalized_string(value)
    value.to_s.strip.presence
  end

  def success(actuator)
    Result.new(success: true, status: :accepted, errors: [], actuator: actuator)
  end

  def failure(status, errors)
    Result.new(success: false, status: status, errors: Array(errors), actuator: ActuatorDevice.current_device)
  end
end
