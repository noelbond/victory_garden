primary_key = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].presence ||
  Rails.application.credentials.dig(:active_record_encryption, :primary_key)
deterministic_key = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].presence ||
  Rails.application.credentials.dig(:active_record_encryption, :deterministic_key)
key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].presence ||
  Rails.application.credentials.dig(:active_record_encryption, :key_derivation_salt)

if primary_key.blank? || deterministic_key.blank? || key_derivation_salt.blank?
  generator = Rails.application.key_generator
  primary_key ||= generator.generate_key("active_record_encryption_primary_key", 32)
  deterministic_key ||= generator.generate_key("active_record_encryption_deterministic_key", 32)
  key_derivation_salt ||= generator.generate_key("active_record_encryption_key_derivation_salt", 32)
end

Rails.application.config.active_record.encryption.primary_key = primary_key
Rails.application.config.active_record.encryption.deterministic_key = deterministic_key
Rails.application.config.active_record.encryption.key_derivation_salt = key_derivation_salt
Rails.application.config.active_record.encryption.support_unencrypted_data = true
