ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "factory_bot_rails"

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all
    include FactoryBot::Syntax::Methods

    # Temporarily replaces klass's singleton method `method_name` with `callable`
    # for the duration of the block, then restores the original implementation.
    def stub_singleton_method(klass, method_name, callable)
      original = klass.method(method_name)
      klass.define_singleton_method(method_name, &callable)
      yield
    ensure
      klass.define_singleton_method(method_name, &original)
    end

    def create_ready_setup_actuator!(line_count:)
      raise "current setup actuator already exists" if ActuatorDevice.current.exists?

      actuator = create(
        :actuator_device,
        logical_node_id: "actuator-setup",
        state: "ready",
        current: true,
        irrigation_line_count: line_count,
        config_status: "applied",
        config_acknowledged_at: Time.current,
        last_seen_at: Time.current,
        provisioned_at: Time.current
      )

      (1..line_count).each do |output_index|
        create(:actuator_output, actuator_device: actuator, output_index: output_index, state: "assigned")
      end

      actuator
    end

    def complete_current_setup_watering!(idempotency_key:, runtime_seconds: 45)
      zone, node = current_setup_watering_target_for_test
      target_attributes = WateringEvent.setup_target_attributes(
        zone: zone,
        node: node,
        runtime_seconds: runtime_seconds
      )

      WateringEvent.create!(
        zone: zone,
        node_id: node&.node_id,
        command: "start_watering",
        runtime_seconds: runtime_seconds,
        reason: "setup_validation",
        issued_at: Time.current,
        idempotency_key: idempotency_key,
        status: "completed",
        setup_validation: true,
        setup_current: true,
        **target_attributes
      )
    end

    def current_setup_watering_target_for_test
      node = Node.assigned.order(last_seen_at: :desc, created_at: :desc).detect(&:watering_configured?)
      return [node.zone, node] if node.present?

      [Zone.order(:created_at, :id).first, nil]
    end
  end
end
