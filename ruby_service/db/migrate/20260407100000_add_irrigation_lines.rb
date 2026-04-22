class AddIrrigationLines < ActiveRecord::Migration[8.0]
  def change
    add_column :connection_settings, :irrigation_line_count, :integer
    add_column :zones, :irrigation_line, :integer
    add_index :zones, :irrigation_line, unique: true, where: "irrigation_line IS NOT NULL"
  end
end
