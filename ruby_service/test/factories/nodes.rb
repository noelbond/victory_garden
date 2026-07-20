FactoryBot.define do
  factory :node do
    sequence(:node_id) { |n| "sensor-#{n}" }
    last_seen_at { Time.current }
  end
end
