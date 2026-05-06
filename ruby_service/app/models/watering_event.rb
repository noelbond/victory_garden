class WateringEvent < ApplicationRecord
  STATUSES = %w[queued command_sent acknowledged running completed stopped fault timeout unknown].freeze

  belongs_to :zone

  validates :command, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :issued_at, presence: true
  validates :idempotency_key, presence: true
  validates :runtime_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  validate :runtime_consistency

  private

  def runtime_consistency
    return unless command == "stop_watering" && runtime_seconds.present?

    errors.add(:runtime_seconds, "must be blank for stop_watering")
  end
end
