class AddDeviceIdToNodes < ActiveRecord::Migration[8.0]
  def change
    add_column :nodes, :device_id, :string
    add_index :nodes, :device_id
  end
end
