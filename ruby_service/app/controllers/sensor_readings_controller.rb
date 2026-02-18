class SensorReadingsController < ApplicationController
  protect_from_forgery with: :null_session

  def ingest
    payload = ingest_params.to_h
    SensorIngestJob.perform_later(payload)
    render json: { status: "queued" }, status: :accepted
  end

  private

  def ingest_params
    params.require(:sensor_reading).permit(
      :node_id,
      :zone_id,
      :timestamp,
      :moisture_raw,
      :moisture_percent,
      :battery_voltage,
      :rssi
    )
  end
end
