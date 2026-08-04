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

  def reading_request_notice_for(node)
    "Reading request queued. The sleeping Pico will receive it on its next scheduled wake. Restart the Pico if you need a reading immediately."
  end

  READING_REQUEST_DEBOUNCE_SECONDS = 30

  # request_reading has no way to tell "the Pi is slow to respond" apart
  # from "the request failed" — callers (the desktop installer in
  # particular) retry on any slow/lost HTTP response, and the retained MQTT
  # command itself gets redelivered to a node on every reconnect. Without
  # this guard, a single slow network blip fans out into several real
  # commands sent to the physical hardware. Debouncing per node_id for a
  # short window makes a retried/duplicate call return the same in-flight
  # command instead of queuing a new one.
  def queue_reading_request(node)
    cache_key = "reading_request_debounce:#{node.node_id}"
    if (cached = Rails.cache.read(cache_key))
      return cached.merge(deduped: true)
    end

    # Beyond the short-window debounce above (retries/redelivery of the SAME
    # attempt), also fold in behind a still-unresolved earlier request rather
    # than queuing a new one -- avoids piling up commands against a node
    # that's slow to respond or offline; the existing one will either land
    # or time out into a visible fault on its own.
    pending = NodeCommand.where(
      node_id: node.node_id,
      command: "request_reading",
      status: NodeCommand::STATUSES - NodeCommand::TERMINAL_STATUSES
    ).order(issued_at: :desc).first

    if pending
      result = { command_id: pending.command_id, requested_at: pending.issued_at.utc.iso8601 }
      Rails.cache.write(cache_key, result, expires_in: READING_REQUEST_DEBOUNCE_SECONDS)
      return result.merge(deduped: true)
    end

    requested_at = Time.current.utc
    command_id = "#{node.node_id}-#{requested_at.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}-request-reading"

    NodeCommand.create!(
      zone: node.zone,
      node_id: node.node_id,
      command: "request_reading",
      command_id: command_id,
      status: "queued",
      issued_at: requested_at
    )

    result = { command_id: command_id, requested_at: requested_at.iso8601 }
    Rails.cache.write(cache_key, result, expires_in: READING_REQUEST_DEBOUNCE_SECONDS)

    # Scheduled independently of RequestReadingJob's own success so a
    # publish failure (even after that job's own retries are exhausted)
    # still surfaces as a visible NODE_COMMAND_TIMEOUT fault and clears the
    # pending-command check above, instead of leaving this command stuck
    # "queued" forever and silently blocking every future request for this
    # node.
    NodeCommandTimeoutJob
      .set(wait: RequestReadingJob::TIMEOUT_SECONDS.seconds)
      .perform_later(command_id: command_id, timeout_seconds: RequestReadingJob::TIMEOUT_SECONDS)

    RequestReadingJob.perform_later(
      zone_id: node.zone.zone_id,
      command_id: command_id,
      node_id: node.node_id
    )

    result.merge(deduped: false)
  end

  def connection_settings_complete?(setting)
    return false unless setting.present? && setting.mqtt_host.present? && setting.mqtt_port.present?

    setting.mqtt_username.present? && setting.mqtt_password.present?
  end

  def system_connection_complete?(setting)
    connection_settings_complete?(setting) && setting&.irrigation_line_count.present?
  end

  def onboarding_zone_complete?
    Zone.exists?
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
