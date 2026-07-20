module SharedParams
  extend ActiveSupport::Concern

  private

  def permitted_connection_setting_params(source = params)
    source.require(:connection_setting).permit(
      :mqtt_host,
      :mqtt_port,
      :mqtt_username,
      :mqtt_password,
      :irrigation_line_count,
      :readings_topic,
      :actuators_topic,
      :command_topic,
      :config_topic,
      :bluetooth_enabled,
      :notes
    )
  end

  def permitted_crop_profile_params(source = params)
    source.require(:crop_profile).permit(
      :crop_name,
      :dry_threshold,
      :max_pulse_runtime_sec,
      :daily_max_runtime_sec,
      :climate_preference,
      :time_to_harvest_days,
      :notes
    )
  end

  def permitted_zone_params(source = params)
    source.require(:zone).permit(
      :name,
      :crop_profile_id,
      :active,
      :irrigation_line,
      :publish_interval_ms
    )
  end
end
