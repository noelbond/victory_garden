class CreateNodeCommands < ActiveRecord::Migration[8.0]
  def change
    create_table :node_commands do |t|
      t.references :zone, null: false, foreign_key: true
      t.string :node_id, null: false
      t.string :command, null: false
      t.string :command_id, null: false
      t.string :status, null: false, default: "queued"
      t.datetime :issued_at, null: false
      t.datetime :acknowledged_at

      t.timestamps
    end

    add_index :node_commands, :command_id, unique: true
    add_index :node_commands, %i[node_id issued_at]
  end
end
