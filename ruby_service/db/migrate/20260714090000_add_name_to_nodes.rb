class AddNameToNodes < ActiveRecord::Migration[8.0]
  def change
    add_column :nodes, :name, :string
  end
end
