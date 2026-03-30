class AddNodeIdRecordedAtIndexToSensorReadings < ActiveRecord::Migration[8.0]
  def change
    add_index :sensor_readings, %i[node_id recorded_at]
  end
end
