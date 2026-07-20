module PayloadContracts
  class ControllerEvent
    include Validation

    REQUIRED_KEYS = %w[zone_id timestamp action].freeze
    OPTIONAL_KEYS = %w[
      moisture_percent
      runtime_seconds
      runtime_seconds_today
      idempotency_key
      reason
      valid_sensor_count
      expected_sensor_count
      valid_node_ids
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

      normalized["timestamp"] = Time.iso8601(normalized.fetch("timestamp")).utc
      validate_float!(normalized, "moisture_percent", min: 0.0, max: 100.0)
      validate_integer!(normalized, "runtime_seconds", min: 0)
      validate_integer!(normalized, "runtime_seconds_today", min: 0)
      validate_integer!(normalized, "valid_sensor_count", min: 0)
      validate_integer!(normalized, "expected_sensor_count", min: 0)
      validate_length!(normalized, "idempotency_key", max: 300)
      validate_length!(normalized, "reason", max: 200)
      validate_string_list!(normalized, "valid_node_ids")
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
