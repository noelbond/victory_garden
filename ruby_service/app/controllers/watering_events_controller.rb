class WateringEventsController < ApplicationController
  def index
    @watering_events = WateringEvent.includes(:zone).order(issued_at: :desc).limit(200)
  end
end
