class NodeDiagnosticEventIngestor
  def initialize(payload)
    @payload = PayloadContracts::NodeDiagnosticEvent.normalize!(payload)
  end

  def call
    zone = Zone.find_by(zone_id: @payload.fetch("zone_id"))
    raise ArgumentError, "Unknown zone_id: #{@payload['zone_id']}" unless zone

    node_id = @payload.fetch("node_id")
    fault_code = @payload.fetch("event_code")
    detail = @payload["detail"]
    recorded_at = @payload.fetch("timestamp")

    # Diagnostic events are node-node_id-scoped (a combined device's own
    # identity, not one of its per-channel Node records -- see
    # NodeConfigAckIngestor for the same distinction), so there's no Node
    # row to fan out to here; the fault_code/node_id pair is enough on its
    # own to identify what happened.
    existing = Fault.find_by(zone: zone, node_id: node_id, fault_code: fault_code, detail: detail, recorded_at: recorded_at)
    return existing if existing

    Fault.create!(zone: zone, node_id: node_id, fault_code: fault_code, detail: detail, recorded_at: recorded_at)
  end
end
