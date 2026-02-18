class ConnectionSetting < ApplicationRecord
  validates :mqtt_port, numericality: { greater_than: 0 }, allow_nil: true
end
