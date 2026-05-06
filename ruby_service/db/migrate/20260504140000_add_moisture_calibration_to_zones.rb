class AddMoistureCalibrationToZones < ActiveRecord::Migration[8.0]
  def up
    add_column :zones, :moisture_raw_dry, :integer
    add_column :zones, :moisture_raw_wet, :integer

    change_column_default :zones, :publish_interval_ms, from: 60_000, to: 3_600_000

    execute <<~SQL
      UPDATE zones
      SET publish_interval_ms = 3600000
      WHERE publish_interval_ms = 60000
    SQL
  end

  def down
    change_column_default :zones, :publish_interval_ms, from: 3_600_000, to: 60_000
    remove_column :zones, :moisture_raw_dry
    remove_column :zones, :moisture_raw_wet
  end
end
