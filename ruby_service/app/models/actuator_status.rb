class ActuatorStatus < ApplicationRecord
  belongs_to :zone
  belongs_to :node, primary_key: :node_id, foreign_key: :node_id, optional: true

  validates :state, presence: true
  validates :recorded_at, presence: true
  validates :node_id, length: { maximum: 100 }, allow_nil: true
  validates :actual_runtime_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :flow_ml, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
end
