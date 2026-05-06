class MoveMoistureCalibrationToNodes < ActiveRecord::Migration[8.0]
  def up
    add_column :nodes, :moisture_raw_dry, :integer
    add_column :nodes, :moisture_raw_wet, :integer

    execute <<~SQL
      UPDATE nodes
      SET moisture_raw_dry = zones.moisture_raw_dry,
          moisture_raw_wet = zones.moisture_raw_wet
      FROM zones
      WHERE nodes.zone_id = zones.id
        AND nodes.moisture_raw_dry IS NULL
        AND nodes.moisture_raw_wet IS NULL
        AND zones.moisture_raw_dry IS NOT NULL
        AND zones.moisture_raw_wet IS NOT NULL
    SQL
  end

  def down
    remove_column :nodes, :moisture_raw_dry
    remove_column :nodes, :moisture_raw_wet
  end
end
