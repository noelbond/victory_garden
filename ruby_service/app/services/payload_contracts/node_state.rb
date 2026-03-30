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

