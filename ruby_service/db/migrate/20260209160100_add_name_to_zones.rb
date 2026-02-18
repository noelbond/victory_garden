class AddNameToZones < ActiveRecord::Migration[8.0]
  def change
    add_column :zones, :name, :string
  end
end
