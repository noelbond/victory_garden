class MoveOptionalTelemetryIntoSensorReadings < ActiveRecord::Migration[8.0]
  def change
    change_table :sensor_readings, bulk: true do |t|
      t.string :schema_version
      t.decimal :soil_temp_c, precision: 5, scale: 2
      t.integer :battery_percent
      t.bigint :uptime_seconds
      t.bigint :wake_count
      t.string :ip_address
      t.string :health
      t.text :last_error
      t.string :publish_reason
      t.jsonb :raw_payload, null: false, default: {}
    end
  end
end
