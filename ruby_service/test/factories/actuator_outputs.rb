FactoryBot.define do
  factory :actuator_output do
    association :actuator_device
    sequence(:output_index) { |n| n }
    state { "unknown" }
  end
end
