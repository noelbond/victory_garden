class Fault < ApplicationRecord
  belongs_to :zone
  belongs_to :node, primary_key: :node_id, foreign_key: :node_id, optional: true

  validates :fault_code, presence: true
  validates :node_id, length: { maximum: 100 }, allow_nil: true
  validates :recorded_at, presence: true
end
