class NodeCommand < ApplicationRecord
  STATUSES = %w[queued command_sent acknowledged timeout].freeze
  TERMINAL_STATUSES = %w[acknowledged timeout].freeze

  belongs_to :zone
  belongs_to :node, primary_key: :node_id, foreign_key: :node_id, optional: true

  validates :command, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :issued_at, presence: true
  validates :command_id, presence: true
  validates :node_id, length: { maximum: 100 }, allow_nil: true
end
