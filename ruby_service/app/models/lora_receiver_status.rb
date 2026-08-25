class LoraReceiverStatus
  STATUS_PATH = Pathname.new(ENV.fetch("LORA_STATUS_PATH", Rails.root.join("tmp/lora_receiver_status.json").to_s))
  DEFAULT_STALE_AFTER_SECONDS = 120

  def self.current(path: STATUS_PATH, environ: ENV, now: Time.current)
    enabled = enabled?(environ)
    return {"enabled" => false, "status" => "disabled"} unless enabled

    return missing_status unless path.exist?

    status = JSON.parse(File.read(path))
    return invalid_status unless status.is_a?(Hash)
    status["enabled"] = true
    status["status"] ||= "unknown"

    return stale_status(status) if stale?(status["updated_at"], now, stale_after_seconds(environ))

    status
  rescue JSON::ParserError, Errno::ENOENT
    invalid_status
  end

  def self.enabled?(environ = ENV)
    environ.fetch("LORA_ENABLED", "false").to_s.casecmp("true").zero?
  end

  def self.stale_after_seconds(environ = ENV)
    Integer(environ.fetch("LORA_STATUS_STALE_AFTER_SECONDS", DEFAULT_STALE_AFTER_SECONDS))
  rescue ArgumentError
    DEFAULT_STALE_AFTER_SECONDS
  end

  def self.missing_status
    {
      "enabled" => true,
      "status" => "missing",
      "last_error" => "LoRa receiver status file is missing"
    }
  end

  def self.invalid_status
    {
      "enabled" => true,
      "status" => "invalid",
      "last_error" => "LoRa receiver status file is invalid JSON"
    }
  end

  def self.stale_status(status)
    status.merge(
      "last_known_status" => status["status"],
      "status" => "stale",
      "last_error" => status["last_error"].presence || "LoRa receiver status is stale"
    )
  end

  def self.stale?(updated_at, now, stale_after_seconds)
    return true if updated_at.blank?

    Time.iso8601(updated_at) < now - stale_after_seconds.seconds
  rescue ArgumentError, TypeError
    true
  end
end
