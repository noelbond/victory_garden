module PayloadContracts
  class ControllerEvent
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

    def validate_float!(payload, key, min:, max:)
      return if payload[key].nil?

      value = Float(payload[key])
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid #{key}: #{payload[key].inspect}"
    else
      raise ArgumentError, "#{key} out of range" unless value.between?(min, max)

      payload[key] = value
    end

    def validate_integer!(payload, key, min:)
      return if payload[key].nil?

      value = Integer(payload[key])
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid #{key}: #{payload[key].inspect}"
    else
      raise ArgumentError, "#{key} out of range" if value < min

      payload[key] = value
    end

    def validate_length!(payload, key, max:)
      return if payload[key].nil?

      value = payload[key].to_s
      raise ArgumentError, "#{key} too long" if value.length > max

      payload[key] = value
    end

    def validate_string_list!(payload, key)
      return if payload[key].nil?

      raise ArgumentError, "invalid #{key}: #{payload[key].inspect}" unless payload[key].is_a?(Array)

      payload[key] = payload[key].map do |value|
        string = value.to_s
        raise ArgumentError, "invalid #{key}: #{payload[key].inspect}" if string.blank?

        string
      end
    end
  end
end
