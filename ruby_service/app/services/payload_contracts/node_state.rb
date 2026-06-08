module PayloadContracts
  class NodeState
    SCHEMA_VERSION = "node-state/v1"
    REQUIRED_KEYS = %w[node_id zone_id timestamp moisture_raw].freeze
    OPTIONAL_KEYS = %w[
      schema_version
      moisture_percent
      soil_temp_c
      battery_voltage
      battery_percent
      wifi_rssi
      uptime_seconds
      wake_count
      ip
      health
      last_error
      publish_reason
    ].freeze
    LEGACY_ALIASES = {
      "rssi" => "wifi_rssi"
    }.freeze

    def self.normalize!(payload)
      new(payload).normalize!
    end

    def initialize(payload)
      @payload = payload
    end

    def normalize!
      raise ArgumentError, "payload must be a JSON object" unless @payload.is_a?(Hash)

      normalized = @payload.deep_stringify_keys
      LEGACY_ALIASES.each do |legacy_key, canonical_key|
        next unless normalized.key?(legacy_key)
        normalized[canonical_key] = normalized[legacy_key] if normalized[canonical_key].nil?
        normalized.delete(legacy_key)
      end

      unknown_keys = normalized.keys - allowed_keys
      raise ArgumentError, "unknown keys: #{unknown_keys.sort.join(', ')}" if unknown_keys.any?

      REQUIRED_KEYS.each do |key|
        raise ArgumentError, "missing required key: #{key}" if normalized[key].blank?
      end

      if normalized["schema_version"].present? && normalized["schema_version"] != SCHEMA_VERSION
        raise ArgumentError, "unsupported schema_version: #{normalized['schema_version']}"
      end

      normalized["recorded_at"] = Time.iso8601(normalized.fetch("timestamp")).utc
      validate_integer!(normalized, "moisture_raw", min: 0, max: 65_535)
      validate_float!(normalized, "moisture_percent", min: 0.0, max: 100.0)
      validate_float!(normalized, "battery_voltage", min: 0.0, max: 10.0)
      validate_integer!(normalized, "battery_percent", min: 0, max: 100)
      validate_integer!(normalized, "wifi_rssi", min: -130, max: 0)
      validate_integer!(normalized, "uptime_seconds", min: 0)
      validate_integer!(normalized, "wake_count", min: 0)
      validate_length!(normalized, "ip", max: 50)
      validate_length!(normalized, "health", max: 50)
      validate_length!(normalized, "last_error", max: 300)
      validate_length!(normalized, "publish_reason", max: 50)
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

    def validate_integer!(payload, key, min:, max: nil)
      return if payload[key].nil?

      value = Integer(payload[key])
    rescue ArgumentError, TypeError
      raise ArgumentError, "invalid #{key}: #{payload[key].inspect}"
    else
      raise ArgumentError, "#{key} out of range" if value < min || (!max.nil? && value > max)

      payload[key] = value
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

    def validate_length!(payload, key, max:)
      return if payload[key].nil?

      value = payload[key].to_s
      raise ArgumentError, "#{key} too long" if value.length > max

      payload[key] = value
    end
  end
end
