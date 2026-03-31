class AddMqttAuthToConnectionSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :connection_settings, :mqtt_username, :string unless column_exists?(:connection_settings, :mqtt_username)
    add_column :connection_settings, :mqtt_password, :string unless column_exists?(:connection_settings, :mqtt_password)
  end
end
