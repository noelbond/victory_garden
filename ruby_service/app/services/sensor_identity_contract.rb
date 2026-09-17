class SensorIdentityContract
  # firmware/pico_w_sensor_node/src/config.h and the dedicated actuator's
  # topology/journal buffers both reserve 32 bytes, including the terminator.
  FIRMWARE_ID_BUFFER_BYTES = 32
  MAX_FIRMWARE_ID_BYTES = FIRMWARE_ID_BUFFER_BYTES - 1
  CHANNELS = (0...Node::EXPECTED_CHANNELS_PER_DEVICE).freeze
  CANONICAL_CHANNEL_SUFFIX_BYTES = "-ch0".bytesize
  MAX_PACKAGE_ID_BYTES = MAX_FIRMWARE_ID_BYTES - CANONICAL_CHANNEL_SUFFIX_BYTES
  FIRMWARE_SAFE_IDENTITY_PATTERN = /\A[A-Za-z0-9_-]+\z/

  class InvalidIdentity < StandardError; end

  class << self
    def validate_provisioning!(zone_id:, package_id:)
      validate_zone_id!(zone_id)
      validate_package_id!(package_id)
      canonical_node_ids(package_id).each { |node_id| validate_node_id!(node_id) }
      true
    end

    def validate_zone_id!(zone_id)
      validate_topic_segment!(zone_id, label: "Zone identity", max_bytes: MAX_FIRMWARE_ID_BYTES)
    end

    def validate_package_id!(package_id)
      validate_topic_segment!(package_id, label: "Sensor package identity", max_bytes: MAX_PACKAGE_ID_BYTES)
    end

    def validate_node_id!(node_id)
      validate_topic_segment!(node_id, label: "Node identity", max_bytes: MAX_FIRMWARE_ID_BYTES)
    end

    def canonical_node_ids(package_id)
      CHANNELS.map { |channel| "#{package_id}-ch#{channel}" }
    end

    private

    def validate_topic_segment!(value, label:, max_bytes:)
      identity = value.to_s
      raise InvalidIdentity, "#{label} is required." if identity.blank?
      raise InvalidIdentity, "#{label} must be valid UTF-8." unless identity.valid_encoding?

      if identity.bytesize > max_bytes
        raise InvalidIdentity, "#{label} must be at most #{max_bytes} bytes for firmware compatibility."
      end

      unless FIRMWARE_SAFE_IDENTITY_PATTERN.match?(identity)
        raise InvalidIdentity, "#{label} must use only ASCII letters, digits, hyphen, or underscore for firmware compatibility."
      end
    end
  end
end
