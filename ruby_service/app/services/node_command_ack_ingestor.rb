class NodeCommandAckIngestor
  def initialize(payload)
    @payload = payload
  end

  # Matched purely by command_id: the device acks using its own base identity
  # (e.g. "combined-zone1"), which may differ from the specific channel node_id
  # the command was addressed to, so node_id is not a reliable match key here.
  def call
    command = NodeCommand.find_by(command_id: @payload["command_id"])
    return if command.nil?
    return command if NodeCommand::TERMINAL_STATUSES.include?(command.status)

    command.update!(status: "acknowledged", acknowledged_at: ack_time)
    command
  end

  private

  def ack_time
    @payload["timestamp"].presence || Time.current
  end
end
