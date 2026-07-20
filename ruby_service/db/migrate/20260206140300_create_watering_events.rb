class CreateWateringEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :watering_events do |t|
      t.references :zone, null: false, foreign_key: true
      t.string :command, null: false
      t.integer :runtime_seconds
      t.string :reason
      t.datetime :issued_at, null: false
      t.string :idempotency_key, null: false
      t.string :status

      t.timestamps
    end

    add_index :watering_events, :idempotency_key, unique: true
    add_index :watering_events, %i[zone_id issued_at]
  end
end
