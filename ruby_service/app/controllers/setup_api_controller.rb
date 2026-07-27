class SetupApiController < ApplicationController
  include SharedParams

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
    zone.crop_profile ||= CropProfile.order(:crop_name).first

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

    render json: {
      assigned: true,
      node: node_payload(node.reload),
      first_zone: zone_payload(zone),
      status: setup_status_payload
    }
  end

  def update_node
    node = setup_node_from_params

    if node.blank?
      render json: { errors: ["Node #{params[:node_id].inspect} has not been detected yet."] }, status: :unprocessable_entity
      return
    end

    if node.update(node_setup_params)
      ConfigPublishJob.perform_later
      render json: {
        node: node_payload(node.reload),
        status: setup_status_payload
      }
    else
      render json: { errors: node.errors.full_messages }, status: :unprocessable_entity
    end
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

    next_wake_at = node.next_expected_wake_at(reference_time: requested_at)
    render json: {
      queued: true,
      command_id: command_id,
      requested_at: requested_at.iso8601,
      next_expected_wake_at: next_wake_at&.utc&.iso8601,
      message: reading_request_notice_for(node),
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
    node = setup_node_from_params
    zone = node&.zone || assignable_zone

    if zone.blank?
      render json: { errors: ["Create a zone before testing watering."] }, status: :unprocessable_entity
      return
    end

    if node.present? && !node.watering_configured?
      render json: { errors: ["Assign a crop profile and pump output before testing watering for #{node.display_name}."] }, status: :unprocessable_entity
      return
    end

    active_scope = zone.watering_events.blocking_start_commands
    active_scope = active_scope.where(node_id: node.node_id) if node.present?
    if active_scope.exists?
      render json: { errors: ["Watering is already active for this target."] }, status: :unprocessable_entity
      return
    end

    result = node.present? ? WateringCommand.start_node(node) : WateringCommand.start(zone)

    render json: {
      queued: true,
      idempotency_key: result.payload[:idempotency_key],
      issued_at: result.payload[:issued_at].utc.iso8601,
      zone: zone_payload(zone),
      node: node.present? ? node_payload(node) : nil
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

    node = setup_node_from_params
    event_scope = zone.watering_events.order(issued_at: :desc, id: :desc)
    event_scope = event_scope.where(node_id: node.node_id) if node.present?
    event = idempotency_key.present? ? event_scope.find_by(idempotency_key: idempotency_key) : event_scope.first
    status_scope = zone.actuator_statuses.order(recorded_at: :desc, id: :desc)
    status_scope = status_scope.where(node_id: node.node_id) if node.present?
    latest_status = status_scope.first

    render json: {
      complete: event.present? && WateringEvent::TERMINAL_STATUSES.include?(event.status),
      event: event.present? ? watering_event_payload(event) : nil,
      actuator_status: latest_status.present? ? actuator_status_payload(latest_status) : nil,
      zone: zone_payload(zone),
      node: node.present? ? node_payload(node) : nil
    }
  end

  private

  def connection_setting_record
    ConnectionSetting.first || ConnectionSetting.new
  end

  def apply_connection_setting_defaults(setting)
    ConnectionSettingDefaults.apply!(setting)
  end

  def setup_status_payload
    assigned_node = Node.assigned.order(last_seen_at: :desc, created_at: :desc).first
    device_grouped = assigned_node&.device_id.present?
    assigned_channels = (device_grouped ? Node.where(device_id: assigned_node.device_id) : Node.where(id: assigned_node&.id)).to_a
    expected_channel_count = device_grouped ? Node::EXPECTED_CHANNELS_PER_DEVICE : 1

    {
      connection_ready: onboarding_step_state(:connection),
      first_zone_ready: first_zone_ready?,
      watering_targets_ready: watering_targets_ready?,
      zone_ready: onboarding_step_state(:zone),
      detected_node_ready: onboarding_step_state(:detected_node),
      assigned_node_ready: onboarding_step_state(:assigned_node),
      reading_ready: onboarding_step_state(:reading),
      calibration_ready: assigned_node.present? &&
        assigned_channels.size == expected_channel_count &&
        assigned_channels.all?(&:calibration_configured?),
      watering_ready: onboarding_step_state(:watering)
    }
  end

  def first_zone_ready?
    Zone.joins(:crop_profile).exists?
  end

  def watering_targets_ready?
    onboarding_step_state(:zone)
  end

  def connection_setting_payload(setting)
    {
      mqtt_host: setting.mqtt_host,
      mqtt_port: setting.mqtt_port,
      mqtt_username: ConnectionSettingDefaults.mqtt_username_for(setting),
      provisioning_mqtt_username: ConnectionSettingDefaults.mqtt_username_for(setting),
      provisioning_mqtt_password: ConnectionSettingDefaults.mqtt_password_for(setting),
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
      name: node.display_name,
      device_id: node.device_id,
      zone_id: node.zone_id,
      zone_name: node.zone&.name,
      assigned: node.assigned?,
      reported_zone_id: node.reported_zone_id,
      provisioned: node.provisioned,
      config_status: node.config_status,
      last_seen_at: node.last_seen_at&.utc&.iso8601,
      moisture_raw_dry: node.moisture_raw_dry,
      moisture_raw_wet: node.moisture_raw_wet,
      calibration_configured: node.calibration_configured?,
      crop_profile_id: node.crop_profile_id,
      crop_profile_name: node.crop_profile&.crop_name,
      effective_crop_profile_id: node.effective_crop_profile&.id,
      effective_crop_profile_name: node.effective_crop_profile&.crop_name,
      irrigation_line: node.irrigation_line,
      watering_configured: node.watering_configured?
    }
  end

  def sensor_reading_payload(reading)
    {
      id: reading.id,
      node_id: reading.node_id,
      recorded_at: reading.recorded_at&.utc&.iso8601,
      moisture_raw: reading.moisture_raw,
      moisture_percent: reading.moisture_percent,
      air_temperature_c: reading.air_temperature_c,
      humidity_percent: reading.humidity_percent,
      greenhouse_alert_status: reading.greenhouse_alert_status,
      health: reading.health,
      last_error: reading.last_error,
      publish_reason: reading.publish_reason,
      battery_percent: reading.battery_percent,
      wifi_rssi: reading.wifi_rssi
    }
  end

  def watering_event_payload(event)
    {
      id: event.id,
      zone_id: event.zone.zone_id,
      node_id: event.node_id,
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
      node_id: status.node_id,
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
    node.present? ? device_payload(node) : nil
  end

  def assigned_node_payload
    node = Node.assigned.order(last_seen_at: :desc, created_at: :desc).first
    node.present? ? device_payload(node) : nil
  end

  def device_payload(node)
    payload = node_payload(node)
    return payload if node.device_id.blank?

    payload.merge(
      node_id: node.device_id,
      channels: node.device_siblings.order(:node_id).map { |channel| node_payload(channel) }
    )
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
    permitted_connection_setting_params
  end

  def crop_profile_params
    permitted_crop_profile_params
  end

  def zone_params
    permitted_zone_params
  end

  def calibration_params
    params.permit(:moisture_raw_dry, :moisture_raw_wet).tap do |permitted|
      permitted[:moisture_raw_dry] = permitted[:moisture_raw_dry].to_i if permitted[:moisture_raw_dry].present?
      permitted[:moisture_raw_wet] = permitted[:moisture_raw_wet].to_i if permitted[:moisture_raw_wet].present?
    end
  end

  def node_setup_params
    params.permit(:name, :crop_profile_id, :irrigation_line).tap do |permitted|
      permitted[:crop_profile_id] = permitted[:crop_profile_id].presence
      permitted[:irrigation_line] = permitted[:irrigation_line].to_i if permitted[:irrigation_line].present?
    end
  end
end
