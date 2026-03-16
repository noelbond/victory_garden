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
      :schema_version,
      :node_id,
      :zone_id,
      :timestamp,
      :moisture_raw,
      :moisture_percent,
      :soil_temp_c,
      :battery_voltage,
      :battery_percent,
      :wifi_rssi,
      :uptime_seconds,
      :wake_count,
      :ip,
      :health,
      :last_error,
      :publish_reason
    )
  end
end
