class ConfigController < ApplicationController
  protect_from_forgery with: :null_session

  def publish
    ConfigPublishJob.perform_later
    render json: { status: "queued" }, status: :accepted
  end
end
