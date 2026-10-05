class CropProfilesController < ApplicationController
  include SharedParams

  helper_method :validated_return_path

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
      applied_node = apply_crop_profile_to_node(@crop_profile)
      notice = applied_node ? "Crop profile created and applied to #{applied_node.display_name}." : "Crop profile created."
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
    permitted_crop_profile_params
  end

  def resolved_return_path(crop_profile)
    validated_return_path || crop_profile_path(crop_profile)
  end

  def validated_return_path
    url_from(params[:return_to]).presence
  end

  def apply_crop_profile_to_node(crop_profile)
    return nil if params[:apply_node_id].blank?

    node = Node.find_by(id: params[:apply_node_id])
    return nil if node.blank? || node.zone.blank?

    node.update!(crop_profile: crop_profile)
    node
  end

end
