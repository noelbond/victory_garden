class CreateConnectionSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :connection_settings do |t|
      t.string :mqtt_host
      t.integer :mqtt_port
      t.string :readings_topic
      t.string :actuators_topic
      t.string :command_topic
      t.string :config_topic
      t.boolean :bluetooth_enabled, null: false, default: false
      t.text :notes

      t.timestamps
    end
  end
end
