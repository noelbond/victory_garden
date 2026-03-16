class RenameSensorReadingsRssiToWifiRssi < ActiveRecord::Migration[8.0]
  def change
    rename_column :sensor_readings, :rssi, :wifi_rssi
  end
end
