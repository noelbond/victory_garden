class OnboardingController < ApplicationController
  FIRMWARE_BOARD_OPTIONS = {
    "pico_w" => {
      label: "Pico W",
      chip: "RP2040",
      boot_drive: "RPI-RP2"
    },
    "pico2_w" => {
      label: "Pico 2 W",
      chip: "RP2350",
      boot_drive: "RP2350"
    }
  }.freeze

  FIRMWARE_BUNDLE_FILENAMES = {
    "sensor" => {
      "pico_w" => "pico_w_sensor_node.uf2",
      "pico2_w" => "pico2_w_sensor_node.uf2"
    },
    "actuator" => {
      "pico_w" => "pico_w_actuator_node.uf2",
      "pico2_w" => "pico2_w_actuator_node.uf2"
    }
  }.freeze

  helper_method :onboarding_wizard_steps, :onboarding_current_step, :onboarding_previous_step, :onboarding_next_step,
                :firmware_bundle_path, :wizard_auto_refresh_interval_ms, :wizard_auto_refresh_url,
                :selected_firmware_board, :firmware_board_options, :firmware_board_label, :firmware_board_chip,
                :firmware_boot_drive_label, :onboarding_step_path, :firmware_bundle_filename

  def show
    prepare_onboarding_view
  end

  def update_connection
    @setting = connection_setting_record
    @setting.assign_attributes(connection_setting_params)
    apply_connection_setting_defaults(@setting)

    if @setting.save
      ConfigPublishJob.perform_later
      redirect_to onboarding_step_redirect("zone"), notice: "MQTT and water-zone settings saved."
    else
      render_onboarding_step("connection", status: :unprocessable_entity)
    end
  end

  def create_crop_profile
    @crop_profile_form = onboarding_crop_profile_record
    @crop_profile_form.assign_attributes(onboarding_crop_profile_params)

    if @crop_profile_form.save
      redirect_to onboarding_step_redirect("zone", crop_profile_id: @crop_profile_form.id, zone_draft: zone_draft_params.to_h), notice: "Crop profile created. Finish the zone on this step."
    else
      render_onboarding_step("zone", status: :unprocessable_entity)
    end
  end

  def upsert_zone
    @zone_form = onboarding_zone_record
    @zone_form.assign_attributes(onboarding_zone_params)
    @zone_form.crop_profile ||= default_crop_profile

    if @zone_form.save
      redirect_to onboarding_step_redirect("detected_node"), notice: "First zone saved."
    else
      render_onboarding_step("zone", status: :unprocessable_entity)
    end
  end

  def assign_node
    node = Node.find_by(id: params[:node_id])
    zone = Zone.find_by(id: params[:zone_id])

    if node.blank? || zone.blank?
      redirect_to onboarding_step_redirect("assigned_node"), alert: "Choose both a sensor node and a zone before continuing."
      return
    end

    node.update!(zone: zone)
    PublishNodeConfigJob.perform_later(node.id)

    redirect_to onboarding_step_redirect("reading"), notice: "Node assigned to #{zone.name.presence || zone.zone_id}."
  end

  def publish_config
    ConfigPublishJob.perform_later
    redirect_to onboarding_step_redirect("connection"), notice: "Config publish queued."
  end

  def request_reading
    node = selected_assigned_node

    if node.blank? || node.zone.blank?
      redirect_to onboarding_step_redirect("reading"), alert: "Assign a sensor node before requesting a reading."
      return
    end

    RequestReadingJob.perform_later(
      zone_id: node.zone.zone_id,
      command_id: "#{node.node_id}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-request-reading",
      node_id: node.node_id
    )

    redirect_to onboarding_step_redirect("reading"), notice: "Immediate reading requested. Refresh this step after the node responds."
  end

  def water_now
    zone = selected_watering_zone

    if zone.blank?
      redirect_to onboarding_step_redirect("watering"), alert: "Create a zone before testing watering."
      return
    end

    if zone.watering_events.blocking_start_commands.exists?
      redirect_to onboarding_step_redirect("watering"), alert: "Watering is already active for this zone."
      return
    end

    command = {
      command: "start_watering",
      zone_id: zone.zone_id,
      runtime_seconds: zone.crop_profile.max_pulse_runtime_sec,
      reason: "manual_trigger",
      issued_at: Time.current,
      idempotency_key: "#{zone.zone_id}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
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

    redirect_to onboarding_step_redirect("watering"), notice: "Watering command queued. Refresh this step after the actuator responds."
  end

  def firmware
    kind = params[:kind].to_s
    file = firmware_bundle_path(kind, selected_firmware_board(kind))

    unless file&.file?
      redirect_to onboarding_step_path("firmware"), alert: "Firmware bundle is not available for #{kind}."
      return
    end

    send_file file, filename: file.basename.to_s, type: "application/octet-stream", disposition: "attachment"
  end

  def firstboot_log
    unless firstboot_status.available_log?
      redirect_to onboarding_path, alert: "First-boot log is not available on this system."
      return
    end

    send_file firstboot_status.log_path,
              filename: "victory-garden-firstboot.log",
              type: "text/plain; charset=utf-8",
              disposition: "attachment"
  end

  private

  def onboarding_wizard_steps
    @onboarding_wizard_steps
  end

  def onboarding_current_step
    @onboarding_current_step
  end

  def onboarding_previous_step
    @onboarding_previous_step
  end

  def onboarding_next_step
    @onboarding_next_step
  end

  def wizard_auto_refresh_interval_ms
    case onboarding_current_step[:key]
    when "detected_node"
      onboarding_current_step[:done] ? nil : 5000
    when "reading"
      @selected_reading_node.present? && !onboarding_current_step[:done] ? 5000 : nil
    when "watering"
      @selected_watering_zone.present? && waiting_for_watering_confirmation? ? 5000 : nil
    end
  end

  def wizard_auto_refresh_url
    return if wizard_auto_refresh_interval_ms.blank?

    onboarding_path(request.query_parameters.merge(step: onboarding_current_step[:key]))
  end

  def prepare_onboarding_view(step_key = nil)
    @onboarding_wizard_steps = build_onboarding_wizard_steps
    @onboarding_current_step = step_key.present? ? wizard_step_by_key(step_key) : resolve_onboarding_step
    @onboarding_current_step ||= resolve_onboarding_step
    @onboarding_previous_step = wizard_step_before(@onboarding_current_step)
    @onboarding_next_step = wizard_step_after(@onboarding_current_step)
    load_step_context(@onboarding_current_step[:key])
  end

  def render_onboarding_step(step_key, status:)
    prepare_onboarding_view(step_key)
    render :show, status:
  end

  def build_onboarding_wizard_steps
    setting = ConnectionSetting.first
    first_zone = Zone.order(:created_at).first
    discovered_node = Node.order(last_seen_at: :desc, created_at: :desc).first
    assigned_node = Node.assigned.order(last_seen_at: :desc, created_at: :desc).first

    [
      {
        key: "welcome",
        title: "Welcome",
        done: true,
        required: false,
        description: "Use this wizard to bring a brand-new Victory Garden install to its first live reading and first verified watering cycle.",
        checklist: [
          "You only need a browser for the setup steps in this flow.",
          "Enter the required setup information directly in each step, then continue forward.",
          firstboot_status.managed? ? firstboot_status.summary : "This system is not reporting image first-boot provisioning state.",
          "You can reopen this wizard later from Settings any time you add hardware or re-run validation.",
          "Pick the actual board type before flashing. Pico W and Pico 2 W need different UF2 files."
        ],
        actions: [
          { label: "Go To MQTT & Water Zones", path: onboarding_step_path("connection"), class: "btn" }
        ] + firstboot_actions
      },
      {
        key: "connection",
        title: "MQTT & Water Zones",
        done: onboarding_step_state(:connection),
        required: true,
        description: "Confirm the broker settings and tell the app how many physical water-zone outputs exist on the actuator hardware.",
        checklist: [
          connection_settings_complete?(setting) ? "MQTT host, port, username, and password are configured." : "MQTT host, port, username, and password still need setup.",
          setting&.irrigation_line_count.present? ? "Installed water zones: #{setting.irrigation_line_count}." : "Installed water zones still need setup."
        ],
        actions: []
      },
      {
        key: "firmware",
        title: "Flash Devices",
        done: onboarding_step_state(:detected_node),
        required: false,
        description: "Download the bundled Pico firmwares, flash the sensor and actuator boards, then power them on near the Pi.",
        checklist: [
          firmware_available_for_kind?("sensor") ? "Sensor Pico firmware bundles are available for supported boards." : "Sensor Pico firmware is not bundled on this system yet.",
          firmware_available_for_kind?("actuator") ? "Actuator Pico firmware bundles are available for supported boards." : "Actuator Pico firmware is not bundled on this system yet.",
          onboarding_step_state(:detected_node) ? "At least one sensor node has already been detected." : "No sensor node has been detected by the app yet."
        ],
        actions: firmware_actions
      },
      {
        key: "zone",
        title: "Create First Zone",
        done: onboarding_step_state(:zone),
        required: true,
        description: "Create the first zone, attach a Crop Profile, and set the matching Water Zone number for the actuator hardware.",
        checklist: [
          first_zone.present? ? "Current first zone: #{first_zone.name.presence || first_zone.zone_id}." : "No zones exist yet.",
          first_zone&.irrigation_line.present? ? "Water Zone #{first_zone.irrigation_line} is assigned." : "The first zone still needs a Water Zone assignment.",
          CropProfile.exists? ? "At least one crop profile is ready to assign." : "Create the first crop profile directly on this step before saving the zone."
        ],
        actions: []
      },
      {
        key: "detected_node",
        title: "Detect Sensor Node",
        done: onboarding_step_state(:detected_node),
        required: true,
        description: "Flash the sensor Pico, power it near the Pi, and wait for the app to detect its first live state publish.",
        checklist: [
          discovered_node.present? ? "Latest discovered node: #{discovered_node.node_id}." : "No sensor nodes have been discovered yet.",
          discovered_node&.reported_zone_id.present? ? "Reported Zone ID: #{discovered_node.reported_zone_id}." : "The node has not reported a zone identifier yet."
        ],
        actions: []
      },
      {
        key: "assigned_node",
        title: "Assign Sensor Node",
        done: onboarding_step_state(:assigned_node),
        required: true,
        description: "Assign the discovered sensor node to the zone you created so readings can be persisted and used by the controller.",
        checklist: [
          assigned_node.present? ? "Assigned node: #{assigned_node.node_id} -> #{assigned_node.zone.name.presence || assigned_node.zone.zone_id}." : "No sensor node is assigned to a zone yet."
        ],
        actions: []
      },
      {
        key: "reading",
        title: "Confirm First Reading",
        done: onboarding_step_state(:reading),
        required: true,
        description: "Request a reading from the assigned node and confirm it lands in Reading History and on the zone page.",
        checklist: [
          onboarding_step_state(:reading) ? "At least one persisted reading exists." : "No persisted readings exist yet."
        ],
        actions: []
      },
      {
        key: "watering",
        title: "Confirm First Watering",
        done: onboarding_step_state(:watering),
        required: true,
        description: "Run one manual watering cycle and confirm the Watering Events table and zone page show the actuator history correctly.",
        checklist: [
          onboarding_step_state(:watering) ? "Watering history exists for this install." : "No watering history exists yet."
        ],
        actions: []
      },
      {
        key: "done",
        title: "Finish",
        done: !onboarding_incomplete?,
        required: false,
        description: "The minimum live system validation is complete. You can now move into normal operations and reopen this wizard whenever you add or replace hardware.",
        checklist: [
          onboarding_incomplete? ? "There are still required setup steps left." : "All required setup steps are complete."
        ],
        actions: [
          { label: "Open Zones", path: zones_path, class: "btn" },
          { label: "Open Health", path: health_path, class: "btn light" }
        ]
      }
    ]
  end

  def resolve_onboarding_step
    requested = params[:step].presence
    return wizard_step_by_key(requested) if wizard_step_by_key(requested).present?

    return wizard_step_by_key(first_incomplete_step_key) if first_incomplete_step_key.present?

    wizard_step_by_key("done")
  end

  def first_incomplete_step_key
    onboarding_wizard_steps.find { |step| step[:required] && !step[:done] }&.dig(:key)
  end

  def wizard_step_by_key(key)
    onboarding_wizard_steps.find { |step| step[:key] == key.to_s }
  end

  def wizard_step_before(step)
    index = onboarding_wizard_steps.index(step)
    return if index.blank? || index.zero?

    onboarding_wizard_steps[index - 1]
  end

  def wizard_step_after(step)
    index = onboarding_wizard_steps.index(step)
    return if index.blank? || index >= onboarding_wizard_steps.length - 1

    onboarding_wizard_steps[index + 1]
  end

  def firmware_actions
    actions = []

    if firmware_bundle_path("sensor", selected_firmware_board("sensor"))&.file?
      actions << { label: "Download Sensor Firmware (#{firmware_board_label(selected_firmware_board('sensor'))})", path: onboarding_firmware_path(kind: "sensor", board: selected_firmware_board("sensor")), class: "btn" }
    end

    if firmware_bundle_path("actuator", selected_firmware_board("actuator"))&.file?
      actions << { label: "Download Actuator Firmware (#{firmware_board_label(selected_firmware_board('actuator'))})", path: onboarding_firmware_path(kind: "actuator", board: selected_firmware_board("actuator")), class: "btn light" }
    end

    actions
  end

  def firstboot_actions
    return [] unless firstboot_status.managed?

    actions = []
    if firstboot_status.failed?
      actions << { label: "Download First-Boot Log", path: onboarding_firstboot_log_path, class: "btn light" }
      actions << { label: "Open Settings", path: settings_path, class: "btn light" }
    elsif firstboot_status.running?
      actions << { label: "Refresh Wizard", path: onboarding_step_path("welcome"), class: "btn light" }
    end
    actions
  end

  def load_step_context(step_key)
    case step_key.to_s
    when "connection"
      @setting ||= connection_setting_record
      apply_connection_setting_defaults(@setting)
    when "zone"
      @zone_form ||= onboarding_zone_record
      apply_zone_draft(@zone_form)
      @crop_profile_form ||= onboarding_crop_profile_record
      @crop_profiles = CropProfile.order(:crop_name)
      @reading_frequency_options = ZonesController::READING_FREQUENCY_OPTIONS
    when "detected_node"
      @latest_detected_node = Node.order(last_seen_at: :desc, created_at: :desc).first
    when "assigned_node"
      @assignable_nodes = Node.order(last_seen_at: :desc, node_id: :asc)
      @assignable_zones = Zone.order(:created_at, :id)
      @selected_assignment_node = selected_assignment_node
      @selected_assignment_zone = selected_assignment_zone
    when "reading"
      @assigned_nodes = Node.assigned.includes(:zone).order(last_seen_at: :desc, node_id: :asc)
      @selected_reading_node = selected_assigned_node
      @latest_selected_reading = latest_reading_for(@selected_reading_node)
    when "watering"
      @watering_zones = Zone.includes(:crop_profile).order(:created_at, :id)
      @selected_watering_zone = selected_watering_zone
      @latest_watering_event = @selected_watering_zone&.watering_events&.order(issued_at: :desc)&.first
    end
  end

  def connection_setting_record
    ConnectionSetting.first || ConnectionSetting.new
  end

  def apply_connection_setting_defaults(setting)
    setting.mqtt_host = ENV["MQTT_HOST"].presence || "127.0.0.1" if setting.mqtt_host.blank?
    setting.mqtt_port = (ENV["MQTT_PORT"].presence || 1883).to_i if setting.mqtt_port.blank?
    setting.mqtt_username = ENV["MQTT_USERNAME"].presence || "victory_garden" if setting.mqtt_username.blank?
    setting.mqtt_password = ENV["MQTT_PASSWORD"] if setting.mqtt_password.blank? && ENV["MQTT_PASSWORD"].present?
    setting.readings_topic = "greenhouse/zones/+/nodes/+/state" if setting.readings_topic.blank?
    setting.actuators_topic = "greenhouse/zones/+/actuator/status" if setting.actuators_topic.blank?
    setting.command_topic = "greenhouse/zones/{zone_id}/actuator/command" if setting.command_topic.blank?
    setting.config_topic = "greenhouse/system/config/current" if setting.config_topic.blank?
    setting.bluetooth_enabled = false if setting.bluetooth_enabled.nil?
  end

  def onboarding_zone_record
    zone = Zone.order(:created_at, :id).first || Zone.new(active: true)
    zone.crop_profile ||= selected_crop_profile_for_onboarding
    zone.publish_interval_ms ||= Zone::DEFAULT_PUBLISH_INTERVAL_MS
    zone
  end

  def apply_zone_draft(zone)
    return if zone_draft_params.empty?

    zone.assign_attributes(zone_draft_params)
    zone.crop_profile ||= selected_crop_profile_for_onboarding
  end

  def onboarding_crop_profile_record
    CropProfile.new(
      dry_threshold: 30.0,
      max_pulse_runtime_sec: 45,
      daily_max_runtime_sec: 300
    )
  end

  def default_crop_profile
    CropProfile.order(:crop_name).first
  end

  def selected_crop_profile_for_onboarding
    requested_id = params[:crop_profile_id].presence
    CropProfile.find_by(id: requested_id) || default_crop_profile
  end

  def selected_assignment_node
    node_id = params[:node_id].presence
    Node.find_by(id: node_id) || Node.unassigned.order(last_seen_at: :desc, node_id: :asc).first || Node.assigned.order(last_seen_at: :desc, node_id: :asc).first
  end

  def selected_assignment_zone
    zone_id = params[:zone_id].presence
    Zone.find_by(id: zone_id) || selected_assignment_node&.zone || Zone.order(:created_at, :id).first
  end

  def selected_assigned_node
    node_id = params[:node_id].presence || params[:reading_node_id].presence
    scope = Node.assigned.includes(:zone).order(last_seen_at: :desc, node_id: :asc)
    node_id.present? ? scope.find_by(id: node_id) || scope.first : scope.first
  end

  def latest_reading_for(node)
    return if node.blank?

    SensorReading.where(node_id: node.node_id).order(recorded_at: :desc).first
  end

  def selected_watering_zone
    zone_id = params[:zone_id].presence || params[:watering_zone_id].presence
    scope = Zone.includes(:crop_profile).order(:created_at, :id)
    zone_id.present? ? scope.find_by(id: zone_id) || scope.first : scope.first
  end

  def waiting_for_watering_confirmation?
    return false if @latest_watering_event.blank?

    !WateringEvent::TERMINAL_STATUSES.include?(@latest_watering_event.status)
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

  def onboarding_zone_params
    params.require(:zone).permit(
      :name,
      :crop_profile_id,
      :active,
      :irrigation_line,
      :publish_interval_ms
    )
  end

  def onboarding_crop_profile_params
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

  def zone_draft_params
    params.fetch(:zone_draft, {}).permit(
      :name,
      :active,
      :irrigation_line,
      :publish_interval_ms
    )
  end

  def firmware_board_options
    FIRMWARE_BOARD_OPTIONS
  end

  def selected_firmware_board(kind)
    requested_board = params["#{kind}_board"].presence || params[:board].presence
    return requested_board if firmware_board_options.key?(requested_board)

    "pico_w"
  end

  def firmware_board_label(board)
    firmware_board_options.fetch(board).fetch(:label)
  end

  def firmware_board_chip(board)
    firmware_board_options.fetch(board).fetch(:chip)
  end

  def firmware_boot_drive_label(board)
    firmware_board_options.fetch(board).fetch(:boot_drive)
  end

  def onboarding_step_path(step_key, extra_params = {})
    onboarding_path(request.query_parameters.merge(step: step_key).merge(extra_params))
  end

  def onboarding_step_redirect(step_key, extra_params = {})
    onboarding_path(current_firmware_selection_params.merge(step: step_key).merge(extra_params))
  end

  def firmware_bundle_filename(kind, board)
    FIRMWARE_BUNDLE_FILENAMES.fetch(kind.to_s, {}).fetch(board.to_s, nil)
  end

  def firmware_available_for_kind?(kind)
    firmware_board_options.keys.any? { |board| firmware_bundle_path(kind, board)&.file? }
  end

  def current_firmware_selection_params
    {
      sensor_board: selected_firmware_board("sensor"),
      actuator_board: selected_firmware_board("actuator")
    }
  end

  def firmware_bundle_path(kind, board = nil)
    board ||= selected_firmware_board(kind)
    bundle_root = ENV["VG_FIRMWARE_BUNDLE_ROOT"].presence && Pathname.new(ENV["VG_FIRMWARE_BUNDLE_ROOT"])
    filename = firmware_bundle_filename(kind, board)
    return if filename.blank?

    return bundle_root.join(filename) if bundle_root.present?

    bundled_path = Rails.root.join("..", "firmware-bundles", filename).expand_path
    return bundled_path if bundled_path.file?

    case [kind.to_s, board.to_s]
    in ["sensor", "pico_w"]
      Rails.root.join("..", "firmware", "pico_w_sensor_node", "build", filename).expand_path
    in ["actuator", "pico_w"]
      Rails.root.join("..", "firmware", "pico_w_actuator_node", "build", filename).expand_path
    else
      bundled_path
    end
  end
end
