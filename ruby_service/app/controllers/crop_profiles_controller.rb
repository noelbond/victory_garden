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
      applied_zone = apply_crop_profile_to_zone(@crop_profile)
      notice = applied_zone ? "Crop profile created and applied to #{applied_zone.name.presence || applied_zone.zone_id}." : "Crop profile created."
      redirect_to resolved_return_path(@crop_profile), notice: notice
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

  def apply_crop_profile_to_zone(crop_profile)
    return nil if params[:apply_zone_id].blank?

    zone = Zone.find_by(id: params[:apply_zone_id])
    return nil if zone.blank?

    zone.update!(crop_profile: crop_profile)
    zone
  end
end
