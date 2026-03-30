class ConfigController < ApplicationController
  protect_from_forgery with: :null_session
  before_action :require_admin_token

  def publish
    ConfigPublishJob.perform_later
    render json: { status: "queued" }, status: :accepted
  end

  private

  def require_admin_token
    expected = ENV["ADMIN_API_TOKEN"].presence
    return render json: { error: "forbidden" }, status: :forbidden unless expected

    provided = request.headers["Authorization"]&.delete_prefix("Bearer ")
    return if ActiveSupport::SecurityUtils.secure_compare(expected, provided.to_s)

    render json: { error: "unauthorized" }, status: :unauthorized
  end
end
