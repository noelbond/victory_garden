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

  test "invalid irrigation_line_count below existing assignment renders show with error" do
    create(:zone, irrigation_line: 3)

    patch settings_path, params: {
      connection_setting: { irrigation_line_count: 2 }
    }

    assert_response :unprocessable_entity
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
