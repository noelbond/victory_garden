class Fault < ApplicationRecord
  belongs_to :zone

  validates :fault_code, presence: true
  validates :recorded_at, presence: true
end
