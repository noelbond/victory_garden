module PayloadContracts
  class ActuatorStatus
    include Validation

    STATES = %w[ACKNOWLEDGED RUNNING COMPLETED STOPPED FAULT].freeze
    REQUIRED_KEYS = %w[zone_id state timestamp].freeze
    OPTIONAL_KEYS = %w[
      node_id
      idempotency_key
      actual_runtime_seconds
      flow_ml
      fault_code
      fault_detail
    ].freeze

    def self.normalize!(payload)
      new(payload).normalize!
    end

    def initialize(payload)
      @payload = payload
    end

    def normalize!
      raise ArgumentError, "payload must be a JSON object" unless @payload.is_a?(Hash)

      normalized = @payload.deep_stringify_keys
      unknown_keys = normalized.keys - allowed_keys
      raise ArgumentError, "unknown keys: #{unknown_keys.sort.join(', ')}" if unknown_keys.any?

      REQUIRED_KEYS.each do |key|
        raise ArgumentError, "missing required key: #{key}" if normalized[key].blank?
      end

      unless STATES.include?(normalized["state"])
        raise ArgumentError, "unsupported state: #{normalized['state']}"
      end

      normalized["timestamp"] = Time.iso8601(normalized.fetch("timestamp")).utc
      validate_integer!(normalized, "actual_runtime_seconds", min: 0, max: 3600)
      validate_integer!(normalized, "flow_ml", min: 0, max: 10_000_000)
      validate_length!(normalized, "node_id", max: 100)
      validate_length!(normalized, "idempotency_key", max: 300)
      validate_length!(normalized, "fault_code", max: 50)
      validate_length!(normalized, "fault_detail", max: 300)
      normalized
    rescue ArgumentError
      raise
    rescue StandardError => e
      raise ArgumentError, e.message
    end

    private

    def allowed_keys
      REQUIRED_KEYS + OPTIONAL_KEYS
    end
  end
end
