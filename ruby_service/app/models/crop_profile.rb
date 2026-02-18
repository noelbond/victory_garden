class CropProfile < ApplicationRecord
  has_many :zones, dependent: :restrict_with_error

  validates :crop_id, presence: true, uniqueness: true
  validates :crop_name, presence: true
  validates :dry_threshold, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :runtime_seconds, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :max_daily_runtime_seconds, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :time_to_harvest_days, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
end
