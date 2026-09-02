class NodeCommandAckIngestor
  def initialize(payload)
    @payload = payload.to_h.stringify_keys
  end

  # Matched purely by command_id: the device acks using its own base identity
  # (e.g. "combined-zone1"), which may differ from the specific channel node_id
  # the command was addressed to, so node_id is not a reliable match key here.
  def call
    command = NodeCommand.includes(:zone).find_by(command_id: @payload["command_id"])
    return if command.nil?
    return command if NodeCommand::TERMINAL_STATUSES.include?(command.status)

    case @payload["status"]
    when "acknowledged"
      command.update!(status: "acknowledged", acknowledged_at: ack_time)
    when "failed", "rejected"
      command.update!(status: "timeout")
      record_failure_fault(command)
    end

    command
  end

  private

  def record_failure_fault(command)
    Fault.create!(
      zone: command.zone,
      node_id: command.node_id,
      fault_code: "NODE_COMMAND_TIMEOUT",
      detail: "#{command.command} command #{@payload['command_id']} was #{@payload['status']} by #{@payload['node_id']}: #{failure_error}",
      recorded_at: ack_time
    )
  end

  def failure_error
    @payload["error"].presence || "unknown_error"
  end

  def ack_time
    @payload["timestamp"].presence || Time.current
  end
end
