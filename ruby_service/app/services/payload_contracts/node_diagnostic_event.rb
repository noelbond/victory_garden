module PayloadContracts
  class NodeDiagnosticEvent
    include Validation

    SCHEMA_VERSION = "node-diagnostic-event/v1"
    EVENT_CODES = %w[
      BROKER_UNREACHABLE
      BROKER_DISCOVERY_NO_RESPONSE
      BROKER_DISCOVERY_REJECTED
      BROKER_DISCOVERY_APPLIED
    ].freeze
    REQUIRED_KEYS = %w[node_id zone_id event_code timestamp].freeze
    OPTIONAL_KEYS = %w[schema_version detail].freeze

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

      if normalized["schema_version"].present? && normalized["schema_version"] != SCHEMA_VERSION
        raise ArgumentError, "unsupported schema_version: #{normalized['schema_version']}"
      end

      unless EVENT_CODES.include?(normalized["event_code"])
        raise ArgumentError, "unsupported event_code: #{normalized['event_code']}"
      end

      device_timestamp = Time.iso8601(normalized.fetch("timestamp")).utc
      # Same 1970 NTP-not-synced sentinel as node-state/v1 (see NodeState) --
      # a diagnostic event fires right as a node reconnects after an outage,
      # which can race NTP sync on a fresh boot (e.g. right after the
      # Wi-Fi-outage forced reboot), so this is a realistic case here too,
      # not just for routine sensor readings.
      normalized["timestamp"] = device_timestamp.year <= 1971 ? Time.current.utc : device_timestamp
      validate_length!(normalized, "node_id", max: 100)
      validate_length!(normalized, "zone_id", max: 100)
      validate_length!(normalized, "detail", max: 300)
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
