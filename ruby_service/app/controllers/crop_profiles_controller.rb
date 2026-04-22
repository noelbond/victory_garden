class CropProfilesController < ApplicationController
  def index
    @crop_profiles = CropProfile.order(:crop_name)
  end

  def show
    @crop_profile = CropProfile.find(params[:id])
  end

  def new
    @crop_profile = CropProfile.new
  end

  def create
    @crop_profile = CropProfile.new(crop_profile_params)

    if @crop_profile.save
      redirect_to resolved_return_path(@crop_profile), notice: "Crop profile created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @crop_profile = CropProfile.find(params[:id])
  end

  def update
    @crop_profile = CropProfile.find(params[:id])

    if @crop_profile.update(crop_profile_params)
      redirect_to resolved_return_path(@crop_profile), notice: "Crop profile updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def crop_profile_params
    params.require(:crop_profile).permit(
      :crop_name,
      :dry_threshold,
      :max_pulse_runtime_sec,
      :daily_max_runtime_sec,
      :climate_preference,
      :time_to_harvest_days,
      :notes
    )
  end

  def resolved_return_path(crop_profile)
    url_from(params[:return_to]).presence || crop_profile_path(crop_profile)
  end
end
