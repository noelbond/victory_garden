class AddEnvironmentToSensorReadings < ActiveRecord::Migration[8.0]
  def change
    change_column_null :sensor_readings, :moisture_raw, true
    add_column :sensor_readings, :air_temperature_c, :decimal, precision: 5, scale: 2
    add_column :sensor_readings, :humidity_percent, :decimal, precision: 5, scale: 2
    add_column :sensor_readings, :soil_moisture_read, :boolean, default: false, null: false
    add_column :sensor_readings, :greenhouse_alert_status, :string, default: "normal", null: false
  end
end
