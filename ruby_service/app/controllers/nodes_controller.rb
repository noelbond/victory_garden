class NodesController < ApplicationController
  before_action :set_node, only: %i[show claim unclaim publish_config request_reading reboot crop_profile update_calibration]
  before_action :load_show_dependencies, only: %i[show update_calibration]

  def index
    @nodes = Node.includes(:zone).order(last_seen_at: :desc, node_id: :asc)
    @unclaimed_nodes = @nodes.select { |node| !node.claimed? }
    @claimed_nodes = @nodes.select(&:claimed?)
  end

  def show
  end

  def claim
    zone = Zone.find(params.require(:zone_id))

    @node.update!(zone: zone)
    PublishNodeConfigJob.perform_later(@node.id)

    redirect_to node_path(@node), notice: "Node claimed for #{zone.name.presence || zone.zone_id}."
  end

  def unclaim
    if @node.zone.present?
      @node.update!(zone: nil)
      PublishNodeConfigJob.perform_later(@node.id)
    end

    redirect_to nodes_path, notice: "Node unclaimed."
  end

  def publish_config
    PublishNodeConfigJob.perform_later(@node.id)
    redirect_to resolved_return_path, notice: "Node config publish queued."
  end

  def request_reading
    return unless require_claimed_zone_for_command("Claim the node before requesting a reading.")

    RequestReadingJob.perform_later(
      zone_id: @node.zone.zone_id,
      command_id: "#{@node.node_id}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-request-reading",
      node_id: @node.node_id
    )
    redirect_to resolved_return_path, notice: "Immediate reading requested."
  end

  def reboot
    return unless require_claimed_zone_for_command("Claim the node before sending a reboot command.")

    RebootNodeJob.perform_later(
      zone_id: @node.zone.zone_id,
      command_id: "#{@node.node_id}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-reboot",
      node_id: @node.node_id
    )
    redirect_to resolved_return_path, notice: "Node reboot queued."
  end

  def crop_profile
    if @node.zone.blank?
      redirect_to node_path(@node), alert: "Claim the node before assigning a crop profile."
      return
    end

    crop_profile = CropProfile.find(params.require(:crop_profile_id))
    @node.zone.update!(crop_profile: crop_profile)

    redirect_to node_path(@node), notice: "Crop profile updated for #{@node.zone.name.presence || @node.zone.zone_id}."
  end

  def update_calibration
    if @node.update(node_calibration_params)
      redirect_to resolved_return_path, notice: "Node calibration updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def resolved_return_path
    url_from(params[:return_to]).presence || node_path(@node)
  end

  def require_claimed_zone_for_command(message)
    if @node.zone.blank?
      redirect_to resolved_return_path, alert: message
      return false
    end

    true
  end

  def set_node
    @node = Node.find(params[:id])
  end

  def load_show_dependencies
    @available_zones = Zone.order(:zone_id)
    @crop_profiles = CropProfile.order(:crop_name)
  end

  def node_calibration_params
    params.require(:node).permit(:moisture_raw_dry, :moisture_raw_wet)
  end
end
