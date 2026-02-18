class CreateSensorReadings < ActiveRecord::Migration[8.0]
  def change
    create_table :sensor_readings do |t|
      t.references :zone, null: false, foreign_key: true
      t.string :node_id, null: false
      t.datetime :recorded_at, null: false
      t.integer :moisture_raw, null: false
      t.decimal :moisture_percent, precision: 5, scale: 2
      t.decimal :battery_voltage, precision: 4, scale: 2
      t.integer :rssi

      t.timestamps
    end

    add_index :sensor_readings, %i[zone_id recorded_at]
  end
end
