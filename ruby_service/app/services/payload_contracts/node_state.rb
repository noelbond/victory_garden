module PayloadContracts
  class NodeState
    include Validation

    SCHEMA_VERSION = "node-state/v1"
    REQUIRED_KEYS = %w[node_id zone_id timestamp].freeze
    OPTIONAL_KEYS = %w[
      schema_version
      device_id
      moisture_raw
      moisture_percent
      air_temperature_c
      humidity_percent
      soil_moisture_read
      greenhouse_alert_status
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
      validate_float!(normalized, "air_temperature_c", min: -40.0, max: 125.0)
      validate_float!(normalized, "humidity_percent", min: 0.0, max: 100.0)
      validate_boolean!(normalized, "soil_moisture_read")
      validate_enum!(normalized, "greenhouse_alert_status", %w[normal warning critical])
      validate_float!(normalized, "battery_voltage", min: 0.0, max: 10.0)
      validate_integer!(normalized, "battery_percent", min: 0, max: 100)
      validate_integer!(normalized, "wifi_rssi", min: -130, max: 0)
      validate_integer!(normalized, "uptime_seconds", min: 0)
      validate_integer!(normalized, "wake_count", min: 0)
      validate_length!(normalized, "ip", max: 50)
      validate_length!(normalized, "device_id", max: 64)
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
  end
end
