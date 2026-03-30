class RemoveNodeIdFromZones < ActiveRecord::Migration[8.0]
  def change
    remove_column :zones, :node_id, :string
  end
end
