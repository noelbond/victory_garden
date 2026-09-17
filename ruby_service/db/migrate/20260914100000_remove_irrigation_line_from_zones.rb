class RemoveIrrigationLineFromZones < ActiveRecord::Migration[8.0]
  INDEX_NAME = "index_zones_on_irrigation_line"
  INDEX_WHERE = "irrigation_line IS NOT NULL"

  def up
    remove_index :zones, name: INDEX_NAME
    remove_column :zones, :irrigation_line, :integer
  end

  def down
    add_column :zones, :irrigation_line, :integer, null: true, default: nil
    add_index :zones, :irrigation_line, unique: true, where: INDEX_WHERE, name: INDEX_NAME
  end
end
