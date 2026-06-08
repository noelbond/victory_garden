class SetupApiController < ApplicationController
  skip_forgery_protection

  def bootstrap
    render json: {
      status: setup_status_payload,
      connection_setting: connection_setting_payload(connection_setting_record),
      crop_profiles: CropProfile.order(:crop_name).map { |profile| crop_profile_payload(profile) },
      first_zone: first_zone_payload,
      detected_node: latest_detected_node_payload,
      assigned_node: assigned_node_payload
    }
  end

  def update_connection
    setting = connection_setting_record
    setting.assign_attributes(connection_setting_params)
    apply_connection_setting_defaults(setting)

    if setting.save
      ConfigPublishJob.perform_later
      render json: {
        status: setup_status_payload,
        connection_setting: connection_setting_payload(setting)
      }
    else
      render json: { errors: setting.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def create_crop_profile
    profile = CropProfile.new(crop_profile_params)

    if profile.save
      render json: {
        status: setup_status_payload,
        crop_profile: crop_profile_payload(profile),
        crop_profiles: CropProfile.order(:crop_name).map { |item| crop_profile_payload(item) }
      }, status: :created
    else
      render json: { errors: profile.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def upsert_zone
    zone = Zone.order(:created_at, :id).first || Zone.new(active: true)
    zone.assign_attributes(zone_params)

    if zone.save
      render json: {
        status: setup_status_payload,
        first_zone: zone_payload(zone)
      }
    else
      render json: { errors: zone.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def node_status
    node = Node.find_by(node_id: params[:node_id].to_s)

    render json: {
      detected: node.present?,
      assigned: node&.assigned? || false,
      node: node.present? ? node_payload(node) : nil,
      first_zone: first_zone_payload
    }
  end

  def assign_node
    node = Node.find_by(node_id: params[:node_id].to_s)
    zone = assignable_zone

    if node.blank?
      render json: { errors: ["Node #{params[:node_id].inspect} has not been detected yet."] }, status: :unprocessable_entity
      return
    end

    if zone.blank?
      render json: { errors: ["Create a zone before assigning a node."] }, status: :unprocessable_entity
      return
    end

    node.update!(zone: zone)
    PublishNodeConfigJob.perform_later(node.id)

    render json: {
      assigned: true,
      node: node_payload(node.reload),
      first_zone: zone_payload(zone),
      status: setup_status_payload
    }
  end

  def request_reading
    node = setup_node_from_params || Node.assigned.order(last_seen_at: :desc, created_at: :desc).first

    if node.blank? || node.zone.blank?
      render json: { errors: ["Assign a sensor node before requesting a reading."] }, status: :unprocessable_entity
      return
    end

    requested_at = Time.current.utc
    command_id = "#{node.node_id}-#{requested_at.strftime('%Y%m%dT%H%M%SZ')}-request-reading"

    RequestReadingJob.perform_later(
      zone_id: node.zone.zone_id,
      command_id: command_id,
      node_id: node.node_id
    )

    render json: {
      queued: true,
      command_id: command_id,
      requested_at: requested_at.iso8601,
      node: node_payload(node)
    }
  end

  def reading_status
    node = setup_node_from_params
    since = parse_iso_time(params[:since])

    if node.blank?
      render json: {
        complete: false,
        node: nil,
        reading: nil
      }
      return
    end

    latest_reading = SensorReading.where(node_id: node.node_id).order(recorded_at: :desc).first
    complete = latest_reading.present? && (since.blank? || latest_reading.recorded_at >= since)

    render json: {
      complete: complete,
      node: node_payload(node),
      reading: latest_reading.present? ? sensor_reading_payload(latest_reading) : nil
    }
  end

  def update_calibration
    node = setup_node_from_params || Node.assigned.order(last_seen_at: :desc, created_at: :desc).first

    if node.blank?
      render json: { errors: ["Assign a sensor node before saving calibration."] }, status: :unprocessable_entity
      return
    end

    if node.zone.blank?
      render json: { errors: ["Assign the sensor node to a zone before saving calibration."] }, status: :unprocessable_entity
      return
    end

    if node.update(calibration_params)
      render json: {
        node: node_payload(node.reload),
        status: setup_status_payload
      }
    else
      render json: { errors: node.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def start_watering
    zone = assignable_zone

    if zone.blank?
      render json: { errors: ["Create a zone before testing watering."] }, status: :unprocessable_entity
      return
    end

    if zone.watering_events.blocking_start_commands.exists?
      render json: { errors: ["Watering is already active for this zone."] }, status: :unprocessable_entity
      return
    end

    issued_at = Time.current.utc
    idempotency_key = "#{zone.zone_id}-#{issued_at.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
    command = {
      command: "start_watering",
      zone_id: zone.zone_id,
      runtime_seconds: zone.crop_profile.max_pulse_runtime_sec,
      reason: "manual_trigger",
      issued_at: issued_at,
      idempotency_key: idempotency_key
    }

    WateringEvent.create!(
      zone: zone,
      command: command[:command],
      runtime_seconds: command[:runtime_seconds],
      reason: command[:reason],
      issued_at: command[:issued_at],
      idempotency_key: command[:idempotency_key],
      status: "queued"
    )
    CommandPublishJob.perform_later(command)

    render json: {
      queued: true,
      idempotency_key: idempotency_key,
      issued_at: issued_at.iso8601,
      zone: zone_payload(zone)
    }
  end

  def watering_status
    zone = assignable_zone
    idempotency_key = params[:idempotency_key].to_s

    if zone.blank?
      render json: {
        complete: false,
        event: nil,
        actuator_status: nil,
        zone: nil
      }
      return
    end

    event_scope = zone.watering_events.order(issued_at: :desc, id: :desc)
    event = idempotency_key.present? ? event_scope.find_by(idempotency_key: idempotency_key) : event_scope.first
    latest_status = zone.actuator_statuses.order(recorded_at: :desc, id: :desc).first

    render json: {
      complete: event.present? && WateringEvent::TERMINAL_STATUSES.include?(event.status),
      event: event.present? ? watering_event_payload(event) : nil,
      actuator_status: latest_status.present? ? actuator_status_payload(latest_status) : nil,
      zone: zone_payload(zone)
    }
  end

  private

  def connection_setting_record
    ConnectionSetting.first || ConnectionSetting.new
  end

  def apply_connection_setting_defaults(setting)
    setting.mqtt_host = ENV["MQTT_HOST"].presence || "127.0.0.1" if setting.mqtt_host.blank?
    setting.mqtt_port = (ENV["MQTT_PORT"].presence || 1883).to_i if setting.mqtt_port.blank?
    # The Pi-managed broker credentials are authoritative for first-run setup.
    # The desktop installer provisions Pico nodes with these exact values, so
    # allowing arbitrary setup-time overrides here would break broker auth.
    setting.mqtt_username = effective_mqtt_username(setting)
    setting.mqtt_password = effective_mqtt_password(setting)
    setting.readings_topic = "greenhouse/zones/+/nodes/+/state" if setting.readings_topic.blank?
    setting.actuators_topic = "greenhouse/zones/+/actuator/status" if setting.actuators_topic.blank?
    setting.command_topic = "greenhouse/zones/{zone_id}/actuator/command" if setting.command_topic.blank?
    setting.config_topic = "greenhouse/system/config/current" if setting.config_topic.blank?
    setting.bluetooth_enabled = false if setting.bluetooth_enabled.nil?
  end

  def effective_mqtt_username(setting)
    ENV["MQTT_USERNAME"].presence || setting.mqtt_username.presence || "victory_garden"
  end

  def effective_mqtt_password(setting)
    ENV["MQTT_PASSWORD"].presence || setting.mqtt_password
  end

  def setup_status_payload
    assigned_node = Node.assigned.order(last_seen_at: :desc, created_at: :desc).first

    {
      connection_ready: onboarding_step_state(:connection),
      zone_ready: onboarding_step_state(:zone),
      detected_node_ready: onboarding_step_state(:detected_node),
      assigned_node_ready: onboarding_step_state(:assigned_node),
      reading_ready: onboarding_step_state(:reading),
      calibration_ready: assigned_node&.calibration_configured? || false,
      watering_ready: onboarding_step_state(:watering)
    }
  end

  def connection_setting_payload(setting)
    {
      mqtt_host: setting.mqtt_host,
      mqtt_port: setting.mqtt_port,
      mqtt_username: effective_mqtt_username(setting),
      provisioning_mqtt_username: effective_mqtt_username(setting),
      provisioning_mqtt_password: effective_mqtt_password(setting),
      irrigation_line_count: setting.irrigation_line_count,
      readings_topic: setting.readings_topic,
      actuators_topic: setting.actuators_topic,
      command_topic: setting.command_topic,
      config_topic: setting.config_topic,
      bluetooth_enabled: setting.bluetooth_enabled,
      notes: setting.notes
    }
  end

  def crop_profile_payload(profile)
    {
      id: profile.id,
      crop_id: profile.crop_id,
      crop_name: profile.crop_name,
      dry_threshold: profile.dry_threshold,
      max_pulse_runtime_sec: profile.max_pulse_runtime_sec,
      daily_max_runtime_sec: profile.daily_max_runtime_sec,
      climate_preference: profile.climate_preference,
      time_to_harvest_days: profile.time_to_harvest_days,
      notes: profile.notes
    }
  end

  def zone_payload(zone)
    {
      id: zone.id,
      zone_id: zone.zone_id,
      name: zone.name,
      crop_profile_id: zone.crop_profile_id,
      crop_profile_name: zone.crop_profile&.crop_name,
      irrigation_line: zone.irrigation_line,
      publish_interval_ms: zone.publish_interval_ms,
      active: zone.active
    }
  end

  def node_payload(node)
    {
      id: node.id,
      node_id: node.node_id,
      zone_id: node.zone_id,
      zone_name: node.zone&.name,
      assigned: node.assigned?,
      reported_zone_id: node.reported_zone_id,
      provisioned: node.provisioned,
      config_status: node.config_status,
      last_seen_at: node.last_seen_at&.utc&.iso8601,
      moisture_raw_dry: node.moisture_raw_dry,
      moisture_raw_wet: node.moisture_raw_wet,
      calibration_configured: node.calibration_configured?
    }
  end

  def sensor_reading_payload(reading)
    {
      id: reading.id,
      node_id: reading.node_id,
      recorded_at: reading.recorded_at&.utc&.iso8601,
      moisture_raw: reading.moisture_raw,
      moisture_percent: reading.moisture_percent,
      publish_reason: reading.publish_reason,
      battery_percent: reading.battery_percent,
      wifi_rssi: reading.wifi_rssi
    }
  end

  def watering_event_payload(event)
    {
      id: event.id,
      zone_id: event.zone.zone_id,
      command: event.command,
      status: event.status,
      reason: event.reason,
      runtime_seconds: event.runtime_seconds,
      issued_at: event.issued_at&.utc&.iso8601,
      idempotency_key: event.idempotency_key
    }
  end

  def actuator_status_payload(status)
    {
      id: status.id,
      zone_id: status.zone.zone_id,
      state: status.state,
      recorded_at: status.recorded_at&.utc&.iso8601,
      actual_runtime_seconds: status.actual_runtime_seconds,
      flow_ml: status.flow_ml
    }
  end

  def first_zone_payload
    zone = Zone.order(:created_at, :id).first
    zone.present? ? zone_payload(zone) : nil
  end

  def latest_detected_node_payload
    node = Node.order(last_seen_at: :desc, created_at: :desc).first
    node.present? ? node_payload(node) : nil
  end

  def assigned_node_payload
    node = Node.assigned.order(last_seen_at: :desc, created_at: :desc).first
    node.present? ? node_payload(node) : nil
  end

  def assignable_zone
    if params[:zone_id].present?
      Zone.find_by(id: params[:zone_id]) || Zone.find_by(zone_id: params[:zone_id])
    else
      Zone.order(:created_at, :id).first
    end
  end

  def setup_node_from_params
    node_id = params[:node_id].to_s
    return if node_id.blank?

    Node.find_by(node_id: node_id)
  end

  def parse_iso_time(value)
    return if value.blank?

    Time.iso8601(value)
  rescue ArgumentError
    nil
  end

  def connection_setting_params
    params.require(:connection_setting).permit(
      :mqtt_host,
      :mqtt_port,
      :mqtt_username,
      :mqtt_password,
      :irrigation_line_count,
      :readings_topic,
      :actuators_topic,
      :command_topic,
      :config_topic,
      :bluetooth_enabled,
      :notes
    )
  end

  def crop_profile_params
    params.require(:crop_profile).permit(
      :crop_name,
      :dry_threshold,
      :max_pulse_runtime_sec,
      :daily_max_runtime_sec,
      :climate_preference,
      :time_to_harvest_days,
      :notes
    )
  end

  def zone_params
    params.require(:zone).permit(
      :name,
      :crop_profile_id,
      :active,
      :irrigation_line,
      :publish_interval_ms
    )
  end

  def calibration_params
    params.permit(:moisture_raw_dry, :moisture_raw_wet).tap do |permitted|
      permitted[:moisture_raw_dry] = permitted[:moisture_raw_dry].to_i if permitted[:moisture_raw_dry].present?
      permitted[:moisture_raw_wet] = permitted[:moisture_raw_wet].to_i if permitted[:moisture_raw_wet].present?
    end
  end
end
