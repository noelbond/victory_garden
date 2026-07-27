class ActuatorOutput < ApplicationRecord
  STATES = %w[available assigned disabled faulted unknown].freeze

  belongs_to :actuator_device

  validates :output_index, presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :output_index, uniqueness: { scope: :actuator_device_id }
  validates :state, presence: true, inclusion: { in: STATES }
end
