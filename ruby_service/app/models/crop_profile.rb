class CropProfile < ApplicationRecord
  has_many :zones, dependent: :restrict_with_error

  before_validation :ensure_crop_id, on: :create
  after_commit :enqueue_config_publish, on: :create
  after_commit :enqueue_config_publish_if_relevant_update, on: :update
  after_commit :enqueue_node_config_publish_if_relevant_update, on: :update
  after_commit :enqueue_config_publish, on: :destroy

  validates :crop_id, presence: true, uniqueness: true
  validates :crop_name, presence: true
  validates :dry_threshold, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :max_pulse_runtime_sec, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :daily_max_runtime_sec, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :time_to_harvest_days, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  private

  def ensure_crop_id
    return if crop_id.present? || crop_name.blank?

    base = crop_name.parameterize.presence || "crop"
    candidate = base
    suffix = 2

    while self.class.where(crop_id: candidate).exists?
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end

    self.crop_id = candidate
  end

  def enqueue_config_publish_if_relevant_update
    return unless saved_change_to_crop_id? ||
                  saved_change_to_crop_name? ||
                  saved_change_to_dry_threshold? ||
                  saved_change_to_max_pulse_runtime_sec? ||
                  saved_change_to_daily_max_runtime_sec? ||
                  saved_change_to_climate_preference? ||
                  saved_change_to_time_to_harvest_days? ||
                  saved_change_to_active?

    enqueue_config_publish
  end

  def enqueue_node_config_publish_if_relevant_update
    return unless saved_change_to_crop_id? ||
                  saved_change_to_crop_name? ||
                  saved_change_to_dry_threshold? ||
                  saved_change_to_max_pulse_runtime_sec? ||
                  saved_change_to_daily_max_runtime_sec? ||
                  saved_change_to_climate_preference? ||
                  saved_change_to_time_to_harvest_days? ||
                  saved_change_to_active?

    zones.includes(:nodes).find_each do |zone|
      zone.nodes.find_each { |node| PublishNodeConfigJob.perform_later(node.id) }
    end
  end

  def enqueue_config_publish
    ConfigPublishJob.perform_later
  end
end
