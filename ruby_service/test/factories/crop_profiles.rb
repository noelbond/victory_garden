FactoryBot.define do
  factory :crop_profile do
    sequence(:crop_id) { |n| "crop-#{n}" }
    crop_name { "Tomato" }
    dry_threshold { 30.0 }
    max_pulse_runtime_sec { 45 }
    daily_max_runtime_sec { 300 }
    climate_preference { "Warm, sunny" }
    time_to_harvest_days { 75 }
  end
end

