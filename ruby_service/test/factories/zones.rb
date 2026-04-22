FactoryBot.define do
  factory :zone do
    sequence(:zone_id) { |n| "zone#{n}" }
    sequence(:name) { |n| "Zone #{n}" }
    sequence(:irrigation_line) { |n| n }
    association :crop_profile
  end
end
