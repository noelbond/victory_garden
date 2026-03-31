class HealthController < ApplicationController
  def show
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

    @summary = {
      nodes: @nodes.count,
      claimed_nodes: @nodes.count(&:claimed?),
      stale_nodes: @nodes.count { |node| node.last_seen_at <= 5.minutes.ago },
      fresh_readings: @latest_readings.values.count { |reading| reading.recorded_at > 5.minutes.ago },
      config_errors: @nodes.count { |node| node.config_status == "error" },
      config_pending: @nodes.count { |node| node.config_status == "pending" },
      open_faults: Fault.where(resolved_at: nil).count
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
    return 2 if node.last_seen_at <= 30.minutes.ago
    return 1 if node.last_seen_at <= 5.minutes.ago

    0
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
        label: "Config Ack",
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
        detail: "#{@summary[:stale_nodes]} node#{'s' unless @summary[:stale_nodes] == 1} have not checked in within 5 minutes.",
        tone: "alert"
      }
    end

    stale_readings = @summary[:claimed_nodes] - @summary[:fresh_readings]
    if stale_readings > 0
      items << {
        label: "Stale Readings",
        detail: "#{stale_readings} claimed zone#{'s' unless stale_readings == 1} do not have a fresh reading within 5 minutes.",
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

    items
  end
end
