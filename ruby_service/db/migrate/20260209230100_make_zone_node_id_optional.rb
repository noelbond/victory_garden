class MakeZoneNodeIdOptional < ActiveRecord::Migration[8.0]
  def change
    change_column_null :zones, :node_id, true
  end
end
