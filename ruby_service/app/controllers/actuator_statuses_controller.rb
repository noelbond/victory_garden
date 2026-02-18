class ActuatorStatusesController < ApplicationController
  protect_from_forgery with: :null_session

  def ingest
    payload = ingest_params.to_h
    ActuatorStatusIngestJob.perform_later(payload)
    render json: { status: "queued" }, status: :accepted
  end

  private

  def ingest_params
    params.require(:actuator_status).permit(
      :zone_id,
      :state,
      :timestamp,
      :idempotency_key,
      :actual_runtime_seconds,
      :flow_ml,
      :fault_code,
      :fault_detail
    )
  end
end
