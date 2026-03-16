class CreateNodeTelemetries < ActiveRecord::Migration[8.0]
  def change
    create_table :node_telemetries do |t|
      t.references :zone, null: false, foreign_key: true
      t.string :node_id, null: false
      t.datetime :recorded_at, null: false
      t.string :schema_version
      t.decimal :soil_temp_c, precision: 5, scale: 2
      t.decimal :battery_voltage, precision: 4, scale: 2
      t.integer :battery_percent
      t.integer :wifi_rssi
      t.bigint :uptime_seconds
      t.bigint :wake_count
      t.string :ip_address
      t.string :health
      t.text :last_error
      t.string :publish_reason
      t.timestamps
    end

    add_index :node_telemetries, [:zone_id, :recorded_at]
  end
end
