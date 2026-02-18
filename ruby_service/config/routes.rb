Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"

  root "zones#index"

  resources :zones do
    member do
      post :water_now
      post :stop_watering
      post :toggle_active
    end
  end
  resources :watering_events, only: [:index]
  resources :crop_profiles, only: [:index, :show]
  resource :settings, only: [:show, :update]

  post "ingest/sensor_readings", to: "sensor_readings#ingest"
  post "ingest/actuator_statuses", to: "actuator_statuses#ingest"
  post "admin/publish_config", to: "config#publish"
end
