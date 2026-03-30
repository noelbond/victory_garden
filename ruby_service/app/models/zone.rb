class Zone < ApplicationRecord
  belongs_to :crop_profile
  has_many :nodes, dependent: :nullify
  has_many :sensor_readings, dependent: :destroy
  has_many :watering_events, dependent: :destroy
  has_many :actuator_statuses, dependent: :destroy
  has_many :faults, dependent: :destroy

  before_validation :ensure_ids

  validates :zone_id, presence: true, uniqueness: true
  validates :name, length: { maximum: 100 }, allow_nil: true

  private

  def ensure_ids
    self.zone_id = "zone-#{SecureRandom.hex(3)}" if zone_id.blank?
  end
end
