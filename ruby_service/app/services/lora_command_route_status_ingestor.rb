class LoraCommandRouteStatusIngestor
  SCHEMA_VERSION = "lora-command-route-status/v1"
  FAILURE_FAULT_CODE = "LORA_COMMAND_ROUTE_FAILED"

  def initialize(payload)
    @payload = payload.to_h.stringify_keys
  end

  def call
    validate_payload!
    return unless @payload.fetch("status") == "failed"

    command = NodeCommand.includes(:zone).find_by(command_id: @payload.fetch("message_id"))
    return record_failure_fault(nil) if command.nil?
    return if command.node_id != target_node_id

    command.with_lock do
      next if NodeCommand::TERMINAL_STATUSES.include?(command.status)

      command.update!(status: "timeout")
      record_failure_fault(command)
    end
  end

  private

  def validate_payload!
    raise ArgumentError, "Unsupported schema_version: #{@payload['schema_version']}" unless @payload["schema_version"] == SCHEMA_VERSION
    raise ArgumentError, "Missing message_id" if @payload["message_id"].blank?
    raise ArgumentError, "Missing target_node_id" if target_node_id.blank?
    raise ArgumentError, "Unsupported status: #{@payload['status']}" unless %w[routed failed].include?(@payload["status"])
    raise ArgumentError, "Missing reason" if @payload["status"] == "failed" && @payload["reason"].blank?
  end

  def target_node_id
    @payload["target_node_id"]
  end

  def node
    @node ||= Node.find_by(node_id: target_node_id)
  end

  def event_time
    return Time.current if @payload["timestamp"].blank?

    Time.zone.parse(@payload["timestamp"]) || Time.current
  rescue ArgumentError
    Time.current
  end

  def failure_detail(command)
    command_label = command&.command || "unknown"
    "LoRa gateway failed to route #{command_label} command #{@payload.fetch('message_id')}: #{@payload.fetch('reason')}"
  end

  def record_failure_fault(command)
    Fault.create!(
      zone: command&.zone || node&.zone,
      node_id: target_node_id,
      fault_code: FAILURE_FAULT_CODE,
      detail: failure_detail(command),
      recorded_at: event_time
    )
  end
end
