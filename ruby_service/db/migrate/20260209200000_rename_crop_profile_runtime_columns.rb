class RenameCropProfileRuntimeColumns < ActiveRecord::Migration[8.0]
  def change
    rename_column :crop_profiles, :runtime_seconds, :max_pulse_runtime_sec
    rename_column :crop_profiles, :max_daily_runtime_seconds, :daily_max_runtime_sec
  end
end
