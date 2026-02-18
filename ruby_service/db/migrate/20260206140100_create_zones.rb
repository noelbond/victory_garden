class CreateZones < ActiveRecord::Migration[8.0]
  def change
    create_table :zones do |t|
      t.string :zone_id, null: false
      t.references :crop_profile, null: false, foreign_key: true
      t.string :node_id, null: false
      t.boolean :active, null: false, default: true
      t.jsonb :allowed_hours

      t.timestamps
    end

    add_index :zones, :zone_id, unique: true
  end
end
