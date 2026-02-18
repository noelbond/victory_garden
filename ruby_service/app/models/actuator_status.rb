class ActuatorStatus < ApplicationRecord
  belongs_to :zone

  validates :state, presence: true
  validates :recorded_at, presence: true
  validates :actual_runtime_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :flow_ml, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
end
