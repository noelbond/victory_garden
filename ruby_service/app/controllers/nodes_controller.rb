class NodesController < ApplicationController
  before_action :set_node, only: %i[show claim unclaim publish_config crop_profile]

  def index
    @nodes = Node.includes(:zone).order(last_seen_at: :desc, node_id: :asc)
    @unclaimed_nodes = @nodes.select { |node| !node.claimed? }
    @claimed_nodes = @nodes.select(&:claimed?)
  end

  def show
    @available_zones = Zone.order(:zone_id)
    @crop_profiles = CropProfile.order(:crop_name)
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
    redirect_to node_path(@node), notice: "Node config publish queued."
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

  private

  def set_node
    @node = Node.find(params[:id])
  end
end
