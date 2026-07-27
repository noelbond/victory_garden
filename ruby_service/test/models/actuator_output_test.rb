require "test_helper"

class ActuatorOutputTest < ActiveSupport::TestCase
  test "requires a parent device" do
    output = ActuatorOutput.new(output_index: 1, state: "available")

    assert_not output.valid?
    assert_includes output.errors[:actuator_device], "must exist"
  end

  test "output index must be positive" do
    output = build(:actuator_output, output_index: 0)

    assert_not output.valid?
    assert_includes output.errors[:output_index], "must be greater than 0"
  end

  test "duplicate output indexes for one device are rejected" do
    actuator = create(:actuator_device)
    create(:actuator_output, actuator_device: actuator, output_index: 1)
    output = build(:actuator_output, actuator_device: actuator, output_index: 1)

    assert_not output.valid?
    assert_includes output.errors[:output_index], "has already been taken"
  end

  test "same output index may exist on different devices" do
    create(:actuator_output, actuator_device: create(:actuator_device), output_index: 1)
    output = build(:actuator_output, actuator_device: create(:actuator_device), output_index: 1)

    assert output.valid?
  end

  test "rejects invalid output state" do
    output = build(:actuator_output, state: "watering")

    assert_not output.valid?
    assert_includes output.errors[:state], "is not included in the list"
  end

  test "accepts all valid output states" do
    ActuatorOutput::STATES.each do |state|
      output = build(:actuator_output, state: state)

      assert output.valid?, "expected #{state.inspect} to be valid"
    end
  end

  test "parent deletion removes outputs" do
    actuator = create(:actuator_device)
    output = create(:actuator_output, actuator_device: actuator, output_index: 1)

    actuator.destroy!

    assert_not ActuatorOutput.exists?(output.id)
  end

  test "database constraints reject invalid bypassed output writes" do
    actuator = create(:actuator_device)
    timestamp = Time.current

    assert_raises ActiveRecord::StatementInvalid do
      ActuatorOutput.transaction(requires_new: true) do
        ActuatorOutput.insert_all!([
          {
            actuator_device_id: actuator.id,
            output_index: 0,
            state: "available",
            created_at: timestamp,
            updated_at: timestamp
          }
        ])
      end
    end

    assert_raises ActiveRecord::StatementInvalid do
      ActuatorOutput.transaction(requires_new: true) do
        ActuatorOutput.insert_all!([
          {
            actuator_device_id: actuator.id,
            output_index: 2,
            state: "watering",
            created_at: timestamp,
            updated_at: timestamp
          }
        ])
      end
    end

    create(:actuator_output, actuator_device: actuator, output_index: 3)
    assert_raises ActiveRecord::RecordNotUnique do
      ActuatorOutput.transaction(requires_new: true) do
        ActuatorOutput.insert_all!([
          {
            actuator_device_id: actuator.id,
            output_index: 3,
            state: "available",
            created_at: timestamp,
            updated_at: timestamp
          }
        ])
      end
    end
  end
end
