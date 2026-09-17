require "test_helper"

class SensorIdentityContractTest < ActiveSupport::TestCase
  test "accepts the maximum package size when its canonical Node IDs fit the firmware buffer" do
    package_id = "a" * SensorIdentityContract::MAX_PACKAGE_ID_BYTES

    SensorIdentityContract.validate_provisioning!(zone_id: "zone-1", package_id: package_id)

    assert_equal 27, package_id.bytesize
    assert_equal 31, SensorIdentityContract.canonical_node_ids(package_id).last.bytesize
    assert_equal "#{package_id}-ch3", SensorIdentityContract.canonical_node_ids(package_id).last
  end

  test "rejects a package one byte beyond the canonical Node identity limit" do
    package_id = "a" * (SensorIdentityContract::MAX_PACKAGE_ID_BYTES + 1)

    error = assert_raises(SensorIdentityContract::InvalidIdentity) do
      SensorIdentityContract.validate_provisioning!(zone_id: "zone-1", package_id: package_id)
    end

    assert_match "at most 27 bytes", error.message
  end

  test "keeps Zone identity validation separate while requiring its firmware buffer limit at provisioning" do
    error = assert_raises(SensorIdentityContract::InvalidIdentity) do
      SensorIdentityContract.validate_provisioning!(zone_id: "z" * SensorIdentityContract::FIRMWARE_ID_BUFFER_BYTES, package_id: "sensor-zone-1")
    end

    assert_match "Zone identity must be at most 31 bytes", error.message
  end

  test "accepts the full firmware-safe identity alphabet and generated canonical Node IDs" do
    package_id = "Az09-_"

    assert SensorIdentityContract.validate_provisioning!(zone_id: "Zz09-_", package_id: package_id)
    assert_equal ["Az09-_-ch0", "Az09-_-ch1", "Az09-_-ch2", "Az09-_-ch3"], SensorIdentityContract.canonical_node_ids(package_id)
  end

  test "rejects JSON structural MQTT wildcard whitespace control and arbitrary punctuation characters" do
    [
      "sensor\"package", "sensor\\package", "sensor[package", "sensor]package",
      "sensor{package", "sensor}package", "sensor,package", "sensor:package",
      "sensor/package", "sensor+package", "sensor#package", " package", "package ",
      "\tpackage", "package\n", "pack age", "sensor\tpackage", "sensor\npackage",
      "sensor.package", "sensor@package", "sensor%package", "sensor=package", "sensor!package"
    ].each do |package_id|
      assert_raises(SensorIdentityContract::InvalidIdentity) do
        SensorIdentityContract.validate_package_id!(package_id)
      end
    end
  end

  test "accepts normal hyphenated package identities" do
    %w[sensor-zone-1 greenhouse_a package_0].each do |package_id|
      assert SensorIdentityContract.validate_provisioning!(zone_id: "zone-1", package_id: package_id)
    end
  end

  test "rejects an unsafe maximum-length package identity" do
    package_id = ("a" * (SensorIdentityContract::MAX_PACKAGE_ID_BYTES - 1)) + "\""

    error = assert_raises(SensorIdentityContract::InvalidIdentity) do
      SensorIdentityContract.validate_package_id!(package_id)
    end

    assert_match "only ASCII letters", error.message
  end

  test "rejects an unsafe Zone identity before accepting a package topology" do
    error = assert_raises(SensorIdentityContract::InvalidIdentity) do
      SensorIdentityContract.validate_provisioning!(zone_id: "zone\"unsafe", package_id: "sensor-zone-1")
    end

    assert_match "Zone identity must use only ASCII letters", error.message
  end
end
