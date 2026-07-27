require "test_helper"

class ActuatorDeviceTest < ActiveSupport::TestCase
  def valid_attrs
    {
      logical_node_id: "actuator-zone1",
      firmware_kind: "actuator",
      state: "pending_observation"
    }
  end

  test "requires logical node id" do
    actuator = ActuatorDevice.new(valid_attrs.merge(logical_node_id: nil))

    assert_not actuator.valid?
    assert_includes actuator.errors[:logical_node_id], "can't be blank"
  end

  test "firmware kind is actuator only" do
    actuator = ActuatorDevice.new(valid_attrs.merge(firmware_kind: "sensor"))

    assert_not actuator.valid?
    assert_includes actuator.errors[:firmware_kind], "is not included in the list"
  end

  test "accepts all valid lifecycle states" do
    ActuatorDevice::STATES.each do |state|
      actuator = ActuatorDevice.new(valid_attrs.merge(state: state))

      assert actuator.valid?, "expected #{state.inspect} to be valid"
    end
  end

  test "rejects invalid lifecycle state" do
    actuator = ActuatorDevice.new(valid_attrs.merge(state: "watering"))

    assert_not actuator.valid?
    assert_includes actuator.errors[:state], "is not included in the list"
  end

  test "irrigation line count must be positive when present" do
    assert ActuatorDevice.new(valid_attrs.merge(irrigation_line_count: nil)).valid?

    actuator = ActuatorDevice.new(valid_attrs.merge(irrigation_line_count: 0))
    assert_not actuator.valid?
    assert_includes actuator.errors[:irrigation_line_count], "must be greater than 0"
  end

  test "device uid may be null" do
    actuator = ActuatorDevice.new(valid_attrs.merge(device_uid: nil))

    assert actuator.valid?
  end

  test "duplicate non-null device uids are rejected" do
    ActuatorDevice.create!(valid_attrs.merge(device_uid: "physical-001"))
    actuator = ActuatorDevice.new(valid_attrs.merge(logical_node_id: "actuator-zone2", device_uid: "physical-001"))

    assert_not actuator.valid?
    assert_includes actuator.errors[:device_uid], "has already been taken"
  end

  test "database permits historical reuse of logical node id but rejects duplicate current logical id" do
    ActuatorDevice.create!(valid_attrs.merge(current: false, state: "inactive", superseded_at: Time.current))
    ActuatorDevice.create!(valid_attrs.merge(current: true, state: "observed"))

    assert_raises ActiveRecord::RecordNotUnique do
      ActuatorDevice.transaction(requires_new: true) do
        ActuatorDevice.new(valid_attrs.merge(current: true, state: "configured")).save!(validate: false)
      end
    end
  end

  test "database permits only one current actuator" do
    ActuatorDevice.create!(valid_attrs.merge(current: true, state: "observed"))

    assert_raises ActiveRecord::RecordNotUnique do
      ActuatorDevice.transaction(requires_new: true) do
        ActuatorDevice.new(
          valid_attrs.merge(
            logical_node_id: "actuator-zone2",
            current: true,
            state: "observed"
          )
        ).save!(validate: false)
      end
    end
  end

  test "current actuator cannot be superseded" do
    actuator = ActuatorDevice.new(valid_attrs.merge(current: true, superseded_at: Time.current))

    assert_not actuator.valid?
    assert_includes actuator.errors[:current], "actuator cannot be current after supersession"
  end

  test "database constraints reject invalid bypassed writes" do
    timestamp = Time.current

    assert_raises ActiveRecord::StatementInvalid do
      ActuatorDevice.transaction(requires_new: true) do
        ActuatorDevice.insert_all!([
          valid_attrs.merge(
            logical_node_id: "actuator-bypassed-kind",
            firmware_kind: "sensor",
            created_at: timestamp,
            updated_at: timestamp
          )
        ])
      end
    end

    assert_raises ActiveRecord::StatementInvalid do
      ActuatorDevice.transaction(requires_new: true) do
        ActuatorDevice.insert_all!([
          valid_attrs.merge(
            logical_node_id: "actuator-bypassed-state",
            state: "watering",
            created_at: timestamp,
            updated_at: timestamp
          )
        ])
      end
    end

    assert_raises ActiveRecord::StatementInvalid do
      ActuatorDevice.transaction(requires_new: true) do
        ActuatorDevice.insert_all!([
          valid_attrs.merge(
            logical_node_id: "actuator-bypassed-count",
            irrigation_line_count: 0,
            created_at: timestamp,
            updated_at: timestamp
          )
        ])
      end
    end
  end

  test "bypassed attempts cannot leave two current actuator rows" do
    timestamp = Time.current

    assert_raises ActiveRecord::RecordNotUnique do
      ActuatorDevice.transaction(requires_new: true) do
        ActuatorDevice.insert_all!([
          valid_attrs.merge(
            logical_node_id: "actuator-current-a",
            current: true,
            created_at: timestamp,
            updated_at: timestamp
          ),
          valid_attrs.merge(
            logical_node_id: "actuator-current-b",
            current: true,
            created_at: timestamp,
            updated_at: timestamp
          )
        ])
      end
    end

    assert_equal 0, ActuatorDevice.current.count
  end
end
