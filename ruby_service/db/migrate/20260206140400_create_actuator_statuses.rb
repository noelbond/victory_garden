class CreateActuatorStatuses < ActiveRecord::Migration[8.0]
  def change
    create_table :actuator_statuses do |t|
      t.references :zone, null: false, foreign_key: true
      t.string :state, null: false
      t.datetime :recorded_at, null: false
      t.string :idempotency_key
      t.integer :actual_runtime_seconds
      t.integer :flow_ml
      t.string :fault_code
      t.text :fault_detail

      t.timestamps
    end

    add_index :actuator_statuses, %i[zone_id recorded_at]
  end
end
