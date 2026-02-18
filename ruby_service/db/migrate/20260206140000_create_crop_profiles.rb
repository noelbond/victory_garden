class CreateCropProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :crop_profiles do |t|
      t.string :crop_id, null: false
      t.string :crop_name, null: false
      t.decimal :dry_threshold, precision: 5, scale: 2, null: false
      t.integer :runtime_seconds, null: false
      t.integer :max_daily_runtime_seconds, null: false
      t.text :notes
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :crop_profiles, :crop_id, unique: true
  end
end
