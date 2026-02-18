class SettingsController < ApplicationController
  def show
    @setting = ConnectionSetting.first || ConnectionSetting.new
  end

  def update
    @setting = ConnectionSetting.first || ConnectionSetting.new
    if @setting.update(setting_params)
      redirect_to settings_path, notice: "Connection settings updated."
    else
      render :index, status: :unprocessable_entity
    end
  end

  private

  def setting_params
    params.require(:connection_setting).permit(
      :mqtt_host,
      :mqtt_port,
      :readings_topic,
      :actuators_topic,
      :command_topic,
      :config_topic,
      :bluetooth_enabled,
      :notes
    )
  end
end
