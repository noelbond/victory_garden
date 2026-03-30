class CreateNodes < ActiveRecord::Migration[8.0]
  def change
    create_table :nodes do |t|
      t.string :node_id, null: false
      t.references :zone, null: true, foreign_key: true
      t.string :reported_zone_id
      t.datetime :last_seen_at, null: false
      t.string :schema_version
      t.boolean :provisioned, null: false, default: false
      t.decimal :battery_voltage, precision: 4, scale: 2
      t.integer :wifi_rssi
      t.string :health
      t.text :last_error
      t.timestamps
    end

    add_index :nodes, :node_id, unique: true
  end
end
