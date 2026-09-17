require "test_helper"

class SettingsTest < ActionDispatch::IntegrationTest
  test "valid update redirects to settings with notice" do
    get settings_path
    assert_response :success

    patch settings_path, params: {
      connection_setting: { mqtt_host: "broker.local", mqtt_port: 1883 }
    }

    assert_redirected_to settings_path
    assert_equal "Connection settings updated.", flash[:notice]
  end

  test "invalid mqtt_port renders show with unprocessable entity" do
    patch settings_path, params: {
      connection_setting: { mqtt_port: 0 }
    }

    assert_response :unprocessable_entity
  end

  test "invalid mqtt_port above 65535 renders show with unprocessable entity" do
    patch settings_path, params: {
      connection_setting: { mqtt_port: 70_000 }
    }

    assert_response :unprocessable_entity
  end

  test "invalid mqtt_host renders show with unprocessable entity" do
    patch settings_path, params: {
      connection_setting: { mqtt_host: "bad host name", mqtt_port: 1883 }
    }

    assert_response :unprocessable_entity
  end

  test "reducing installed capacity preserves higher logical node assignments" do
    zone = create(:zone)
    Node.create!(node_id: "sensor-zone1-ch3", zone: zone, irrigation_line: 3, last_seen_at: Time.current)

    patch settings_path, params: {
      connection_setting: { irrigation_line_count: 2 }
    }

    assert_redirected_to settings_path
    assert_equal 3, Node.find_by!(node_id: "sensor-zone1-ch3").irrigation_line
  end

  test "valid irrigation_line_count change saves and redirects" do
    patch settings_path, params: {
      connection_setting: { irrigation_line_count: 4 }
    }

    assert_redirected_to settings_path
    assert_equal "Connection settings updated.", flash[:notice]
  end

  test "settings page renders without existing record" do
    ConnectionSetting.delete_all

    get settings_path

    assert_response :success
    assert_includes response.body, "Save stores these connection settings in the app database."
    assert_includes response.body, "Publish Config sends the current saved system configuration to MQTT"
  end
end
