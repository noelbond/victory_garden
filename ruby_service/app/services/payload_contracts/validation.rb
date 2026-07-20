module PayloadContracts
  # Shared field-level validators for the PayloadContracts::* payload normalizers.
  # Each validator mutates `payload[key]` in place (coercing to the target type)
  # and raises ArgumentError with a consistent message shape on failure.
  module Validation
    private

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

    def validate_boolean!(payload, key)
      return if payload[key].nil? || payload[key] == true || payload[key] == false

      raise ArgumentError, "invalid #{key}: #{payload[key].inspect}"
    end

    def validate_enum!(payload, key, allowed)
      return if payload[key].nil? || allowed.include?(payload[key])

      raise ArgumentError, "invalid #{key}: #{payload[key].inspect}"
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
