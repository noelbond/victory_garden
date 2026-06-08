class AddIndexToWateringEventsOnZoneIdAndStatus < ActiveRecord::Migration[8.0]
  def change
    add_index :watering_events, [:zone_id, :status]
  end
end
