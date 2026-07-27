class SetupApiController < ApplicationController
  include SharedParams

  skip_forgery_protection

  def bootstrap
    setup_watering = authoritative_setup_watering_event

    render json: {
      status: setup_status_payload,
      setup_watering: setup_watering_payload(setup_watering),
      setup_actuator: SetupActuatorAuthority.bootstrap_payload,
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

  def record_actuator_provisioning
    result = ActuatorProvisioningRecorder.call(actuator_provisioning_params)
    setup_actuator = SetupActuatorAuthority.new(result.actuator).bootstrap_payload

    if result.success?
      render json: {
        recorded: true,
        setup_actuator: setup_actuator,
        status: setup_status_payload,
        message: "Rails recorded the current actuator provisioning attempt and is waiting for matching MQTT configuration acknowledgement."
      }, status: result.status
    else
      render json: {
        recorded: false,
        errors: result.errors,
        setup_actuator: setup_actuator,
        status: setup_status_payload
      }, status: result.status
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

    existing_setup_attempt = authoritative_setup_watering_event
    if existing_setup_attempt&.setup_unresolved?
      render json: {
        errors: ["Watering validation is already active for setup."],
        setup_watering: setup_watering_payload(existing_setup_attempt)
      }, status: :conflict
      return
    end

    active_scope = zone.watering_events.blocking_start_commands
    active_scope = active_scope.where(node_id: node.node_id) if node.present?
    if active_scope.exists?
      render json: { errors: ["Watering is already active for this target."] }, status: :unprocessable_entity
      return
    end

    blocked_event = nil
    result = nil

    begin
      WateringEvent.transaction do
        current = authoritative_setup_watering_event(lock: true)

        if current&.setup_unresolved?
          blocked_event = current
          next
        end

        current&.supersede_setup_validation!(reason: "retry")
        result = WateringCommand.start_setup_validation(zone, node: node, enqueue: false)
      end
    rescue ActiveRecord::RecordNotUnique
      blocked_event = authoritative_setup_watering_event
    end

    if blocked_event.present?
      render json: {
        errors: ["Watering validation is already active for setup."],
        setup_watering: setup_watering_payload(blocked_event)
      }, status: :conflict
      return
    end

    if result.blank?
      render json: {
        errors: ["Watering validation could not be started."],
        setup_watering: setup_watering_payload(authoritative_setup_watering_event)
      }, status: :conflict
      return
    end

    CommandPublishJob.perform_later(result.payload)

    render json: {
      queued: true,
      complete: false,
      terminal: false,
      outcome: "pending",
      message: "Watering command queued.",
      idempotency_key: result.payload[:idempotency_key],
      issued_at: result.payload[:issued_at].utc.iso8601,
      setup_watering: setup_watering_payload(result.event),
      zone: zone_payload(zone),
      node: node.present? ? node_payload(node) : nil
    }
  end

  def watering_status
    zone = assignable_zone
    idempotency_key = params[:idempotency_key].to_s.strip

    if zone.blank?
      render json: {
        complete: false,
        terminal: true,
        outcome: "missing_zone",
        message: "No setup zone is available for watering validation.",
        event: nil,
        actuator_status: nil,
        zone: nil
      }
      return
    end

    node = setup_node_from_params
    event_scope = zone.watering_events.order(issued_at: :desc, id: :desc)
    event_scope = event_scope.where(node_id: node.node_id) if node.present?
    status_scope = zone.actuator_statuses.order(recorded_at: :desc, id: :desc)
    status_scope = status_scope.where(node_id: node.node_id) if node.present?

    if idempotency_key.blank?
      render json: watering_status_response(
        event: nil,
        actuator_status: nil,
        zone: zone,
        node: node,
        outcome_override: "missing_idempotency_key"
      )
      return
    end

    if idempotency_key.length > 300
      render json: watering_status_response(
        event: nil,
        actuator_status: nil,
        zone: zone,
        node: node,
        outcome_override: "invalid_idempotency_key"
      ), status: :unprocessable_entity
      return
    end

    event = event_scope.find_by(idempotency_key: idempotency_key)
    latest_status = event.present? ? status_scope.where(idempotency_key: idempotency_key).first : nil

    render json: watering_status_response(
      event: event,
      actuator_status: latest_status,
      zone: zone,
      node: node,
      outcome_override: event.present? ? nil : "not_found"
    )
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
    setup_watering = authoritative_setup_watering_event
    watering_targets_ready = watering_targets_ready?

    {
      connection_ready: onboarding_step_state(:connection),
      first_zone_ready: first_zone_ready?,
      watering_targets_ready: watering_targets_ready,
      zone_ready: watering_targets_ready,
      detected_node_ready: onboarding_step_state(:detected_node),
      assigned_node_ready: onboarding_step_state(:assigned_node),
      reading_ready: onboarding_step_state(:reading),
      calibration_ready: assigned_node.present? &&
        assigned_channels.size == expected_channel_count &&
        assigned_channels.all?(&:calibration_configured?),
      watering_ready: setup_watering_ready?(setup_watering)
    }
  end

  def first_zone_ready?
    Zone.joins(:crop_profile).exists?
  end

  def watering_targets_ready?
    SetupWateringTargetAuthority.call.ready?
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

  def actuator_provisioning_params
    permitted = params.require(:actuator_provisioning).permit(
      :logical_node_id,
      :provisioning_operation_id,
      :zone_external_id,
      :board
    )

    {
      logical_node_id: permitted[:logical_node_id],
      provisioning_operation_id: permitted[:provisioning_operation_id],
      zone_external_id: permitted[:zone_external_id],
      board: permitted[:board]
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
      idempotency_key: status.idempotency_key,
      recorded_at: status.recorded_at&.utc&.iso8601,
      actual_runtime_seconds: status.actual_runtime_seconds,
      flow_ml: status.flow_ml
    }
  end

  def watering_status_response(event:, actuator_status:, zone:, node:, outcome_override: nil)
    setup_event = event&.setup_validation?
    if setup_event && event.setup_current?
      target_zone, target_node = current_setup_watering_target
      persist_setup_target_invalidation(event, zone: target_zone, node: target_node)
    end
    event.reload if setup_event && event.persisted?
    outcome = outcome_override || (setup_event ? event.setup_outcome : watering_outcome_for(event&.status))

    {
      complete: watering_status_complete?(event, zone: zone, node: node),
      terminal: setup_event ? event.setup_terminal? : watering_terminal_outcome?(outcome),
      outcome: outcome,
      message: watering_status_message(outcome),
      event: event.present? ? watering_event_payload(event) : nil,
      actuator_status: actuator_status.present? ? actuator_status_payload(actuator_status) : nil,
      setup_watering: setup_event ? setup_watering_payload(event) : nil,
      zone: zone_payload(zone),
      node: node.present? ? node_payload(node) : nil
    }
  end

  def watering_outcome_for(status)
    case status
    when "queued", "requested", "command_sent", "published", "acknowledged", "running"
      "in_progress"
    when "completed"
      "success"
    when "stopped"
      "stopped"
    when "fault", "faulted"
      "faulted"
    when "timeout", "timed_out"
      "timed_out"
    when "unknown"
      "unknown"
    else
      "unsupported"
    end
  end

  def watering_terminal_outcome?(outcome)
    %w[success stopped faulted timed_out unknown unsupported missing_zone missing_idempotency_key invalid_idempotency_key not_found].include?(outcome)
  end

  def watering_status_message(outcome)
    {
      "in_progress" => "Watering is still in progress.",
      "success" => "Watering completed successfully.",
      "stopped" => "Watering stopped before completion was confirmed.",
      "faulted" => "The actuator reported a watering fault.",
      "timed_out" => "Watering timed out before completion was confirmed.",
      "unknown" => "The watering result could not be interpreted.",
      "unsupported" => "The watering result is not supported by this setup API.",
      "target_changed" => "The watering validation target changed. Run a new watering validation after checking the setup target.",
      "superseded" => "This watering validation was superseded by a newer setup attempt.",
      "missing_zone" => "No setup zone is available for watering validation.",
      "missing_idempotency_key" => "The watering attempt idempotency key is required for setup validation.",
      "invalid_idempotency_key" => "The watering attempt idempotency key is invalid.",
      "not_found" => "The current watering attempt could not be found or confirmed."
    }.fetch(outcome, "The watering result could not be interpreted.")
  end

  def watering_status_complete?(event, zone:, node:)
    return false if event.blank?
    return event.status == "completed" unless event.setup_validation?

    target_zone, target_node = event.setup_current? ? current_setup_watering_target : [zone, node]
    event.setup_ready_for?(zone: target_zone, node: target_node)
  end

  def setup_watering_ready?(event)
    zone, node = current_setup_watering_target
    event&.setup_ready_for?(zone: zone, node: node) || false
  end

  def setup_watering_payload(event, zone: nil, node: nil)
    if zone.nil? && node.nil?
      zone, node = current_setup_watering_target
    end

    if event.blank?
      return {
        state: "none",
        complete: false,
        terminal: false,
        outcome: "none",
        message: "No setup watering validation has been started.",
        idempotency_key: nil,
        target_matches_current: false,
        event: nil,
        target: nil
      }
    end

    target_matches = event.setup_target_matches?(zone: zone, node: node)
    {
      state: event.setup_lifecycle_state,
      complete: event.setup_ready_for?(zone: zone, node: node),
      terminal: event.setup_terminal?,
      outcome: event.setup_outcome,
      message: watering_status_message(event.setup_outcome),
      idempotency_key: event.idempotency_key,
      target_matches_current: target_matches,
      invalidated_at: event.setup_invalidated_at&.utc&.iso8601,
      invalidation_reason: event.setup_invalidation_reason,
      superseded_at: event.setup_superseded_at&.utc&.iso8601,
      supersession_reason: event.setup_supersession_reason,
      event: watering_event_payload(event),
      target: setup_watering_target_payload(event)
    }
  end

  def setup_watering_target_payload(event)
    {
      kind: event.setup_target_kind,
      zone_id: event.setup_target_zone_external_id,
      node_id: event.setup_target_node_id,
      irrigation_line: event.setup_target_irrigation_line,
      crop_profile_id: event.setup_target_crop_profile_id,
      runtime_seconds: event.runtime_seconds
    }
  end

  def authoritative_setup_watering_event(lock: false)
    scope = WateringEvent.current_setup_validation.order(issued_at: :desc, id: :desc)
    scope = scope.lock if lock
    event = scope.first
    return nil if event.blank?

    zone, node = current_setup_watering_target
    persist_setup_target_invalidation(event, zone: zone, node: node)
    event.reload
  end

  def persist_setup_target_invalidation(event, zone:, node:)
    return if event.blank? || !event.setup_validation?
    return if event.setup_invalidated_at.present?
    return if event.setup_target_matches?(zone: zone, node: node)

    event.invalidate_setup_validation!(reason: setup_target_invalidation_reason(event, zone: zone, node: node))
  end

  def setup_target_invalidation_reason(event, zone:, node:)
    return "target_missing" if zone.blank?
    return "node_missing" if event.setup_target_kind == "node" && node.blank?
    return "zone_changed" if event.zone_id != zone.id
    return "node_changed" if event.setup_target_node_id.present? && event.setup_target_node_id != node&.node_id

    "target_configuration_changed"
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
