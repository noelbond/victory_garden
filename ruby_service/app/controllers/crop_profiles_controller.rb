class CropProfilesController < ApplicationController
  def index
    @crop_profiles = CropProfile.order(:crop_name)
  end

  def show
    @crop_profile = CropProfile.find(params[:id])
  end
end
