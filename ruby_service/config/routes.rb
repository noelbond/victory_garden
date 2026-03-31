Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "zones#index"
  resource :health, only: [:show], controller: :health
  resource :onboarding, only: [:show], controller: :onboarding

  resources :zones do
    member do
      post :water_now
      post :stop_watering
      post :toggle_active
    end
  end
  resources :watering_events, only: [:index]
  resources :crop_profiles, only: [:index, :show]
  resources :nodes, only: [:index, :show] do
    member do
      patch :claim
      patch :unclaim
      post :publish_config
    end
  end
  resource :settings, only: [:show, :update]

  post "ingest/sensor_readings", to: "sensor_readings#ingest"
  post "ingest/actuator_statuses", to: "actuator_statuses#ingest"
  post "admin/publish_config", to: "config#publish"
end
