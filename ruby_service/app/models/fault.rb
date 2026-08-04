class Fault < ApplicationRecord
  # Optional: most faults are zone-scoped, but a system-wide failure (e.g.
  # ConfigPublishJob) or an ingestion failure whose payload doesn't resolve
  # to a known zone (unknown zone_id, malformed payload) has nowhere
  # zone-specific to attach to.
  belongs_to :zone, optional: true
  belongs_to :node, primary_key: :node_id, foreign_key: :node_id, optional: true

  validates :fault_code, presence: true
  validates :node_id, length: { maximum: 100 }, allow_nil: true
  validates :recorded_at, presence: true
end
