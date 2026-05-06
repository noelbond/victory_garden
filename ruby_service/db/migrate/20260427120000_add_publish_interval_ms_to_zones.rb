class AddPublishIntervalMsToZones < ActiveRecord::Migration[8.0]
  def change
    add_column :zones, :publish_interval_ms, :integer, default: 3_600_000, null: false
  end
end
