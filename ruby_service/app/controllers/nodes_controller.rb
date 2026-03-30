class NodesController < ApplicationController
  before_action :set_node, only: %i[show claim unclaim publish_config]

  def index
    @nodes = Node.includes(:zone).order(last_seen_at: :desc, node_id: :asc)
    @unclaimed_nodes = @nodes.select { |node| !node.claimed? }
    @claimed_nodes = @nodes.select(&:claimed?)
  end

  def show
    @available_zones = Zone.order(:zone_id)
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

  private

  def set_node
    @node = Node.find(params[:id])
  end
end
