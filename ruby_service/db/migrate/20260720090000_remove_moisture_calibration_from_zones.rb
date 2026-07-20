class RemoveMoistureCalibrationFromZones < ActiveRecord::Migration[8.0]
  def change
    remove_column :zones, :moisture_raw_dry, :integer
    remove_column :zones, :moisture_raw_wet, :integer
  end
end
