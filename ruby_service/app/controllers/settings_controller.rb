class SettingsController < ApplicationController
  include SharedParams

  def show
    @setting = ConnectionSetting.first || ConnectionSetting.new
  end

  def update
    @setting = ConnectionSetting.first || ConnectionSetting.new
    @setting.assign_attributes(setting_params)
    if @setting.save
      redirect_to settings_path, notice: "Connection settings updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def setting_params
    permitted_connection_setting_params
  end
end
