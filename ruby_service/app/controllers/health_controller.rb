class HealthController < ApplicationController
  helper_method :node_seen_freshness_state, :reading_freshness_state_for

  def show
    @mqtt_consumer_status = load_mqtt_consumer_status
    @nodes = Node.includes(:zone).to_a.sort_by do |node|
      [
        node_freshness_rank(node),
        config_rank(node),
        node.zone_id.present? ? 0 : 1,
        node.node_id
      ]
    end
    @latest_readings = latest_records(SensorReading).index_by(&:zone_id)
    @latest_actuator_statuses = latest_records(ActuatorStatus).index_by(&:zone_id)
    @recent_faults = Fault.includes(:zone).order(recorded_at: :desc).limit(10)
    @environment_label = Rails.env.production? ? "Production" : Rails.env.titleize
    @recent_activity = build_recent_activity
    assigned_zones = @nodes.filter_map(&:zone).uniq(&:id)

    @summary = {
      nodes: @nodes.count,
      assigned_nodes: @nodes.count(&:assigned?),
      assigned_zones: assigned_zones.count,
      stale_nodes: @nodes.count { |node| node_seen_freshness_state(node) != "ok" },
      fresh_zone_readings: assigned_zones.count { |zone| reading_freshness_state_for(zone) == "ok" },
      config_errors: @nodes.count { |node| node.config_status == "error" },
      config_pending: @nodes.count { |node| node.config_status == "pending" },
      open_faults: Fault.where(resolved_at: nil).count,
      mqtt_consumer_status: @mqtt_consumer_status["status"] || "unknown",
      firstboot_status: firstboot_status.status
    }
    @attention_items = build_attention_items
  end

  private

  def latest_records(model)
    model
      .select("DISTINCT ON (zone_id) #{model.table_name}.*")
      .order(:zone_id, recorded_at: :desc)
  end

  def node_freshness_rank(node)
    case node_seen_freshness_state(node)
    when "offline" then 2
    when "stale" then 1
    else 0
    end
  end

  def config_rank(node)
    case node.config_status
    when "error" then 0
    when "pending" then 1
    else 2
    end
  end

  def build_recent_activity
    items = []

    latest_records(SensorReading).includes(:zone).limit(5).each do |reading|
      items << {
        at: reading.recorded_at,
        label: "Reading",
        detail: "#{reading.zone.name.presence || reading.zone.zone_id}: #{reading.moisture_percent || "—"}%"
      }
    end

    latest_records(ActuatorStatus).includes(:zone).limit(5).each do |status|
      items << {
        at: status.recorded_at,
        label: "Actuator",
        detail: "#{status.zone.name.presence || status.zone.zone_id}: #{status.state}"
      }
    end

    Node.where.not(config_acknowledged_at: nil).includes(:zone).order(config_acknowledged_at: :desc).limit(5).each do |node|
      items << {
        at: node.config_acknowledged_at,
        label: "Config Acknowledged",
        detail: "#{node.node_id}: #{node.config_status || "applied"}"
      }
    end

    items.compact.sort_by { |item| item[:at] }.reverse.first(8)
  end

  def build_attention_items
    items = []

    if @summary[:stale_nodes] > 0
      items << {
        label: "Stale Nodes",
        detail: "#{@summary[:stale_nodes]} node#{'s' unless @summary[:stale_nodes] == 1} have not checked in within the expected interval.",
        tone: "alert"
      }
    end

    stale_readings = @summary[:assigned_zones] - @summary[:fresh_zone_readings]
    if stale_readings > 0
      items << {
        label: "Stale Zone Readings",
        detail: "#{stale_readings} assigned zone#{'s' unless stale_readings == 1} do not have a fresh reading in the expected interval.",
        tone: "warn"
      }
    end

    if @summary[:config_errors] > 0
      items << {
        label: "Config Errors",
        detail: "#{@summary[:config_errors]} node#{'s' unless @summary[:config_errors] == 1} reported config-sync failures.",
        tone: "alert"
      }
    end

    if @summary[:config_pending] > 0
      items << {
        label: "Config Pending",
        detail: "#{@summary[:config_pending]} node#{'s' unless @summary[:config_pending] == 1} are still waiting for config acknowledgement.",
        tone: "warn"
      }
    end

    if @summary[:open_faults] > 0
      items << {
        label: "Open Faults",
        detail: "#{@summary[:open_faults]} unresolved zone fault#{'s' unless @summary[:open_faults] == 1} need review.",
        tone: "alert"
      }
    end

    if @mqtt_consumer_status["status"].in?(%w[retrying degraded])
      detail = "MQTT consumer is #{@mqtt_consumer_status['status']}."
      detail += " Retry #{@mqtt_consumer_status['retry_count']}." if @mqtt_consumer_status["retry_count"].to_i.positive?
      detail += " Last error: #{@mqtt_consumer_status['last_error']}." if @mqtt_consumer_status["last_error"].present?
      detail += " Next retry at #{@mqtt_consumer_status['next_retry_at']}." if @mqtt_consumer_status["next_retry_at"].present?
      items << {
        label: "MQTT Consumer",
        detail: detail,
        tone: @mqtt_consumer_status["status"] == "degraded" ? "alert" : "warn"
      }
    end

    if firstboot_status.failed? || firstboot_status.running?
      items << {
        label: "Image Provisioning",
        detail: firstboot_status.summary,
        tone: firstboot_status.failed? ? "alert" : "warn"
      }
    end

    items
  end

  def load_mqtt_consumer_status
    path = MqttConsumer::STATUS_PATH
    return {} unless path.exist?

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    {}
  end

  def node_seen_freshness_state(node)
    return "offline" if node.last_seen_at.blank?

    freshness_state_for(node.last_seen_at, expected_interval_for(node.zone))
  end

  def reading_freshness_state_for(zone)
    return "offline" if zone.blank?

    reading = @latest_readings[zone.id]
    return "offline" if reading.blank? || reading.recorded_at.blank?

    freshness_state_for(reading.recorded_at, expected_interval_for(zone))
  end

  def expected_interval_for(zone)
    interval_ms = zone&.publish_interval_ms.presence || Zone::DEFAULT_PUBLISH_INTERVAL_MS

    [interval_ms.to_i / 1000.0, 1.0].max
  end

  def freshness_state_for(recorded_at, interval)
    age = Time.current - recorded_at

    return "ok" if age <= interval
    return "stale" if age <= interval * 2

    "offline"
  end
end
