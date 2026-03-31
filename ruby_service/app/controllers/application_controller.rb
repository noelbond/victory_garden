class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :set_onboarding_state

  helper_method :onboarding_incomplete?, :onboarding_steps, :onboarding_completed_count

  private

  def set_onboarding_state
    setting = ConnectionSetting.first
    @onboarding_steps = [
      {
        key: :connection,
        title: "Connection Settings",
        done: connection_settings_complete?(setting),
        path: settings_path,
        description: "Set the MQTT broker host and port. If your broker requires auth, fill in both username and password."
      },
      {
        key: :zone,
        title: "First Zone",
        done: Zone.exists?,
        path: zones_path,
        description: "Create at least one zone and attach a crop profile."
      },
      {
        key: :node,
        title: "Claim A Node",
        done: Node.claimed.exists?,
        path: nodes_path,
        description: "Assign a discovered node to a zone so readings can be persisted and used."
      }
    ]
  end

  def onboarding_steps
    @onboarding_steps
  end

  def onboarding_completed_count
    onboarding_steps.count { |step| step[:done] }
  end

  def onboarding_incomplete?
    onboarding_completed_count < onboarding_steps.length
  end

  def connection_settings_complete?(setting)
    return false unless setting.present? && setting.mqtt_host.present? && setting.mqtt_port.present?

    username_present = setting.mqtt_username.present?
    password_present = setting.mqtt_password.present?
    username_present == password_present
  end
end
