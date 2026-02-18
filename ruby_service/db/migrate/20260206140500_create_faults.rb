class CreateFaults < ActiveRecord::Migration[8.0]
  def change
    create_table :faults do |t|
      t.references :zone, null: false, foreign_key: true
      t.string :fault_code, null: false
      t.text :detail
      t.datetime :recorded_at, null: false
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :faults, %i[zone_id recorded_at]
  end
end
