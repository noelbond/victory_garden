class NodeConfigAckIngestor
  def initialize(payload)
    @payload = payload
  end

  def call
    node = Node.find_by!(node_id: @payload.fetch("node_id"))

    updates = {
      config_acknowledged_at: ack_time,
      config_status: status_value,
      config_error: @payload["error"]
    }

    if @payload["applied_config"].present?
      updates[:applied_config] = @payload["applied_config"]
    elsif node.desired_config.present? && status_value == "applied"
      updates[:applied_config] = node.desired_config
    end

    if @payload["config_version"].present?
      updates[:config_version] = @payload["config_version"]
    end

    if @payload["zone_id"].present?
      updates[:reported_zone_id] = @payload["zone_id"]
    end

    node.update!(updates)
    node
  end

  private

  def ack_time
    @payload["timestamp"].presence || Time.current
  end

  def status_value
    case @payload["status"]
    when "applied" then "applied"
    when "error", "failed" then "error"
    else "pending"
    end
  end
end
