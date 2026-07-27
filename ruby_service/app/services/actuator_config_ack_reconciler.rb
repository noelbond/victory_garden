class ActuatorConfigAckReconciler
  MAX_ERROR_TEXT_LENGTH = 300

  def self.call(payload)
    new(payload).call
  end

  def initialize(payload)
    @payload = payload
  end

  def call
    node_id = payload.fetch("node_id").to_s.strip

    ActuatorDevice.transaction do
      actuator = ActuatorDevice.current_device(lock: true)
      return nil if actuator.blank? || actuator.logical_node_id != node_id

      actuator.reconcile_expected_outputs!
      actuator.actuator_outputs.reload
      actuator.update!(ack_attributes(actuator))
      actuator.reload
    end
  end

  private

  attr_reader :payload

  def ack_attributes(actuator)
    status = status_value
    next_state =
      case status
      when "applied"
        actuator.output_inventory_ready? ? "ready" : "configured"
      when "error"
        "configured"
      else
        "observed"
      end

    {
      state: next_state,
      last_seen_at: ack_time,
      config_acknowledged_at: ack_time,
      config_status: status,
      config_error: status == "error" ? bounded_error : nil
    }
  end

  def ack_time
    @ack_time ||= begin
      raw = payload["timestamp"].presence
      raw.present? ? Time.iso8601(raw) : Time.current
    rescue ArgumentError
      Time.current
    end
  end

  def status_value
    case payload["status"]
    when "applied" then "applied"
    when "error", "failed" then "error"
    else "pending"
    end
  end

  def bounded_error
    payload["error"].to_s.strip.first(MAX_ERROR_TEXT_LENGTH).presence
  end
end
