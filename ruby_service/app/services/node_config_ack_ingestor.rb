class NodeConfigAckIngestor
  def initialize(payload)
    @payload = payload
  end

  def call
    nodes = matching_nodes
    raise ActiveRecord::RecordNotFound, "Couldn't find Node or device with node_id=#{@payload["node_id"]}" if nodes.empty?

    nodes.each { |node| apply_ack(node) }
    nodes.first
  end

  private

  # A combined multi-channel device acks using its shared device identity, which
  # has no Node record of its own -- it only matches the device_id on each of its
  # per-channel Node records. Fan the update out to all of them in that case.
  def matching_nodes
    id = @payload.fetch("node_id")
    direct_matches = Node.where(node_id: id).to_a
    return direct_matches if direct_matches.any?

    Node.where(device_id: id).to_a
  end

  def apply_ack(node)
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
  end

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
