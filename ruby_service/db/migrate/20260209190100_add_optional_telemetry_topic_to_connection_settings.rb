class AddOptionalTelemetryTopicToConnectionSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :connection_settings, :optional_telemetry_topic, :string
  end
end
