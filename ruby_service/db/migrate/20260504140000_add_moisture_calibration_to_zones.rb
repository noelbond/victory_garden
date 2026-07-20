class AddMoistureCalibrationToZones < ActiveRecord::Migration[8.0]
  def up
    add_column :zones, :moisture_raw_dry, :integer
    add_column :zones, :moisture_raw_wet, :integer

    # publish_interval_ms has defaulted to 3_600_000 since it was added
    # (see 20260427120000); this backfills any zone created before that
    # default existed and still carries the old app-level default of 60_000.
    execute <<~SQL
      UPDATE zones
      SET publish_interval_ms = 3600000
      WHERE publish_interval_ms = 60000
    SQL
  end

  def down
    remove_column :zones, :moisture_raw_dry
    remove_column :zones, :moisture_raw_wet
  end
end
