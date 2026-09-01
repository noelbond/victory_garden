class NodeCommandTimeoutJob < ApplicationJob
  queue_as :default

  def perform(command_id:, timeout_seconds:)
    command = NodeCommand.includes(:zone).find_by(command_id: command_id)
    return unless command
    return if NodeCommand::TERMINAL_STATUSES.include?(command.status)

    command.update!(status: "timeout")

    Fault.create!(
      zone: command.zone,
      node_id: command.node_id,
      fault_code: "NODE_COMMAND_TIMEOUT",
      detail: "No #{command_completion_signal(command)} received within #{timeout_seconds}s (#{command_id})",
      recorded_at: Time.current
    )
  end

  private

  def command_completion_signal(command)
    if command.command == "request_reading"
      "#{command.command} result"
    else
      "#{command.command} acknowledgement"
    end
  end
end
