class AddNodeLevelWateringAssignments < ActiveRecord::Migration[8.0]
  def change
    add_reference :nodes, :crop_profile, foreign_key: true
    add_column :nodes, :irrigation_line, :integer
    add_index :nodes, :irrigation_line, unique: true, where: "irrigation_line IS NOT NULL"

    add_column :watering_events, :node_id, :string
    add_index :watering_events, %i[node_id issued_at]

    add_column :actuator_statuses, :node_id, :string
    add_index :actuator_statuses, %i[node_id recorded_at]

    add_column :faults, :node_id, :string
    add_index :faults, %i[node_id recorded_at]
  end
end
