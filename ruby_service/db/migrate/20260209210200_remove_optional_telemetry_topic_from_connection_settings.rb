class RemoveOptionalTelemetryTopicFromConnectionSettings < ActiveRecord::Migration[8.0]
  def change
    remove_column :connection_settings, :optional_telemetry_topic, :string
  end
end
