FactoryBot.define do
  factory :actuator_device do
    sequence(:logical_node_id) { |n| "actuator-zone#{n}" }
    firmware_kind { "actuator" }
    state { "pending_observation" }
    current { false }
  end
end
