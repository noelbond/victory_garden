Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "zones#index"
  resource :health, only: [:show], controller: :health
  resource :onboarding, only: [:show], controller: :onboarding
  patch "onboarding/connection", to: "onboarding#update_connection", as: :onboarding_connection
  post "onboarding/crop_profile", to: "onboarding#create_crop_profile", as: :onboarding_crop_profile
  patch "onboarding/zone", to: "onboarding#upsert_zone", as: :onboarding_zone
  patch "onboarding/assignment", to: "onboarding#assign_node", as: :onboarding_assignment
  post "onboarding/publish_config", to: "onboarding#publish_config", as: :onboarding_publish_config
  post "onboarding/request_reading", to: "onboarding#request_reading", as: :onboarding_request_reading
  post "onboarding/water_now", to: "onboarding#water_now", as: :onboarding_water_now
  get "onboarding/firmware/:kind", to: "onboarding#firmware", as: :onboarding_firmware
  get "onboarding/firstboot_log", to: "onboarding#firstboot_log", as: :onboarding_firstboot_log
  get "reading_history", to: "reading_history#index", as: :reading_history
  get "zones/:id/nodes", to: "zones#nodes", as: :zone_nodes

  resources :zones do
    member do
      post :water_now
      post :stop_watering
      post :toggle_active
    end
  end
  resources :watering_events, only: [:index]
  resources :crop_profiles, only: [:index, :show, :new, :create, :edit, :update]
  resources :nodes, only: [:index, :show] do
    member do
      get :readings
      patch :assign
      patch :unassign
      post :publish_config
      post :request_reading
      post :reboot
      patch :crop_profile
      patch :update_calibration
    end
  end
  resource :settings, only: [:show, :update]

  post "ingest/sensor_readings", to: "sensor_readings#ingest"
  post "ingest/actuator_statuses", to: "actuator_statuses#ingest"
  post "admin/publish_config", to: "config#publish"

  get "setup_api/bootstrap", to: "setup_api#bootstrap"
  patch "setup_api/connection", to: "setup_api#update_connection"
  post "setup_api/crop_profile", to: "setup_api#create_crop_profile"
  patch "setup_api/zone", to: "setup_api#upsert_zone"
  get "setup_api/node_status", to: "setup_api#node_status"
  post "setup_api/assign_node", to: "setup_api#assign_node"
  post "setup_api/request_reading", to: "setup_api#request_reading"
  get "setup_api/reading_status", to: "setup_api#reading_status"
  patch "setup_api/calibration", to: "setup_api#update_calibration"
  post "setup_api/start_watering", to: "setup_api#start_watering"
  get "setup_api/watering_status", to: "setup_api#watering_status"
end
