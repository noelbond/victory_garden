class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :set_onboarding_state

  helper_method :firstboot_status, :onboarding_incomplete?, :onboarding_steps, :onboarding_completed_count, :onboarding_step_state

  private

  def set_onboarding_state
    @firstboot_status = FirstbootStatus.current
    setting = ConnectionSetting.first
    @onboarding_step_state = {
      connection: system_connection_complete?(setting),
      zone: onboarding_zone_complete?,
      detected_node: Node.exists?,
      assigned_node: Node.assigned.exists?,
      reading: onboarding_reading_complete?,
      watering: onboarding_watering_complete?
    }

    @onboarding_steps = [
      {
        key: :connection,
        title: "MQTT & Water Zones",
        done: onboarding_step_state(:connection),
        path: settings_path,
        description: "Set the MQTT broker, auth, and installed water zone count."
      },
      {
        key: :zone,
        title: "Create First Zone",
        done: onboarding_step_state(:zone),
        path: new_zone_path,
        description: "Create at least one zone and attach a crop profile."
      },
      {
        key: :detected_node,
        title: "Detect A Sensor Node",
        done: onboarding_step_state(:detected_node),
        path: nodes_path,
        description: "Flash a sensor Pico and wait for the node to appear in the app."
      },
      {
        key: :assigned_node,
        title: "Assign A Sensor Node",
        done: onboarding_step_state(:assigned_node),
        path: nodes_path,
        description: "Assign the discovered sensor node to a zone so readings can be persisted and used."
      },
      {
        key: :reading,
        title: "Confirm First Reading",
        done: onboarding_step_state(:reading),
        path: reading_history_path,
        description: "Request a reading and confirm it is persisted in Reading History."
      },
      {
        key: :watering,
        title: "Confirm First Watering",
        done: onboarding_step_state(:watering),
        path: watering_events_path,
        description: "Run one manual watering cycle and confirm the event and actuator status history."
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

  def onboarding_step_state(key)
    @onboarding_step_state.fetch(key, false)
  end

  def firstboot_status
    @firstboot_status
  end

  def connection_settings_complete?(setting)
    return false unless setting.present? && setting.mqtt_host.present? && setting.mqtt_port.present?

    setting.mqtt_username.present? && setting.mqtt_password.present?
  end

  def system_connection_complete?(setting)
    connection_settings_complete?(setting) && setting&.irrigation_line_count.present?
  end

  def onboarding_zone_complete?
    Zone.where.not(irrigation_line: nil).exists?
  end

  def onboarding_reading_complete?
    assigned_node_ids = Node.assigned.pluck(:node_id)
    return false if assigned_node_ids.empty?

    SensorReading.where(node_id: assigned_node_ids).exists?
  end

  def onboarding_watering_complete?
    WateringEvent.where(status: WateringEvent::TERMINAL_STATUSES).exists?
  end
end
