class RemoveZoneCropProfileOwnership < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE nodes
      SET crop_profile_id = zones.crop_profile_id
      FROM zones
      WHERE nodes.zone_id = zones.id
        AND nodes.crop_profile_id IS NULL
        AND zones.crop_profile_id IS NOT NULL
    SQL

    remove_foreign_key :zones, :crop_profiles
    remove_index :zones, :crop_profile_id
    remove_column :zones, :crop_profile_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Zone crop ownership cannot be restored without overwriting or discarding node-specific crop assignments."
  end
end
