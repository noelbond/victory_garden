module ApplicationHelper
  ZONE_NOTIFICATION_GUIDANCE = {
    "No fresh aggregate" => {
      description: "The zone does not have enough recent sensor data to compute a trustworthy moisture average.",
      fix: "Check that each claimed node is powered on, assigned to this zone, and publishing recent readings."
    },
    "Partial aggregate" => {
      description: "Some sensor data is recent, but one or more claimed nodes are missing, stale, or not reporting moisture.",
      fix: "Open Nodes for this zone, identify the missing or stale node, then restore power, connectivity, or sensor placement for that node."
    },
    "No readings" => {
      description: "This zone has not persisted any sensor reading yet, so the controller has nothing to evaluate.",
      fix: "Confirm the sensor node is claimed to this zone and publish a fresh reading before relying on automatic watering."
    },
    "Stale reading" => {
      description: "The latest reading is too old to trust for current watering decisions.",
      fix: "Check that the sensor node is online and publishing on schedule, then request or wait for a fresh reading."
    },
    "Open faults" => {
      description: "There are unresolved fault records for this zone that may block or explain recent failures.",
      fix: "Review Recent Faults below, correct the root cause, and verify the zone returns to healthy readings and actuator status."
    },
    "Watering active" => {
      description: "The actuator is currently running for this zone.",
      fix: "No action is needed unless watering is unexpected. If it is unexpected, stop the zone and inspect the latest reading and controller reason."
    }
  }.freeze

  HEALTH_NOTIFICATION_GUIDANCE = {
    "Stale Nodes" => {
      description: "One or more nodes have not checked in recently, so the system cannot trust their current online state.",
      fix: "Check power, Wi-Fi connectivity, and recent node activity, then request a fresh reading or reboot the affected node."
    },
    "Stale Readings" => {
      description: "One or more claimed zones do not have a recent sensor reading available for current automation decisions.",
      fix: "Open the affected node or zone, confirm the sensor is still publishing, and request a fresh reading if needed."
    },
    "Config Errors" => {
      description: "At least one node failed a config publish or config acknowledgement step.",
      fix: "Review the node's config error details, correct MQTT or broker settings if needed, then use Republish Config."
    },
    "Config Pending" => {
      description: "A config update was published but some nodes have not acknowledged applying it yet.",
      fix: "Make sure the node is online, wait for acknowledgement, or republish the config if the node remains pending."
    },
    "Open Faults" => {
      description: "There are unresolved zone fault records that still need operator review.",
      fix: "Open Recent Faults, identify the affected zone or actuator issue, and correct the underlying cause before retrying."
    }
  }.freeze

  FAULT_CODE_GUIDANCE = {
    "ACTUATOR_TIMEOUT" => {
      description: "The system sent a watering command but did not receive a terminal actuator status in time.",
      fix: "Check actuator power, MQTT connectivity, and relay or valve wiring, then retry one watering cycle and confirm ACKNOWLEDGED, RUNNING, and COMPLETED all arrive."
    },
    "NO_FLOW" => {
      description: "The actuator reported that watering started but no water flow was detected.",
      fix: "Check the water source, pump prime, tubing, and valve or relay path for blockage, then run a short manual watering test."
    },
    "LOW_PRESSURE" => {
      description: "The actuator reported insufficient water pressure for a normal run.",
      fix: "Inspect the pump, reservoir level, tubing, and fittings for leaks or restriction before watering again."
    },
    "STALE_SENSOR" => {
      description: "A sensor reading was considered too old to use safely for automatic decisions.",
      fix: "Bring the sensor node back online and confirm a fresh reading is ingested before trusting automation."
    }
  }.freeze

  RUNTIME_ERROR_GUIDANCE = {
    "stale sample" => {
      description: "The latest reading is too old to trust for current automation decisions.",
      fix: "Check that the sensor node is still publishing on schedule and request a fresh reading if needed."
    },
    "sensor drift" => {
      description: "The node reported unstable or suspicious sensor behavior.",
      fix: "Inspect probe placement, wiring, and calibration, then compare a fresh reading against the expected moisture condition."
    }
  }.freeze

  DEFAULT_GUIDANCE = {
    description: "The system reported a condition that needs operator review.",
    fix: "Inspect the related node, zone, and recent activity, then retry the relevant action once the underlying issue is corrected."
  }.freeze

  def issue_guidance_for(kind:, key:, detail: nil)
    registry =
      case kind
      when :zone_notification then ZONE_NOTIFICATION_GUIDANCE
      when :health_notification then HEALTH_NOTIFICATION_GUIDANCE
      when :fault_code then FAULT_CODE_GUIDANCE
      when :runtime_error then RUNTIME_ERROR_GUIDANCE
      else {}
      end

    registry.fetch(key.to_s) do
      {
        description: detail.presence || DEFAULT_GUIDANCE[:description],
        fix: DEFAULT_GUIDANCE[:fix]
      }
    end
  end

  def zone_notification_guidance(item)
    issue_guidance_for(kind: :zone_notification, key: item[:label], detail: item[:detail])
  end

  def health_notification_guidance(item)
    issue_guidance_for(kind: :health_notification, key: item[:label], detail: item[:detail])
  end

  def fault_guidance(fault)
    issue_guidance_for(kind: :fault_code, key: fault.fault_code, detail: fault.detail)
  end

  def node_config_guidance(node)
    status = node.config_status.to_s
    error = node.config_error.to_s

    if error.match?(/connection refused .*localhost.*1883/i)
      return {
        description: "This app tried to publish config to a local MQTT broker on localhost:1883, but no broker accepted the connection.",
        fix: "Open Settings and point MQTT host and port at the real broker for this environment, then use Republish Config again."
      }
    end

    case status
    when "error"
      {
        description: error.presence || "The last config publish or acknowledgement failed for this node.",
        fix: "Review the MQTT settings, confirm the node is online, then republish config and watch for a new config acknowledgement."
      }
    when "pending"
      {
        description: "Config has been published but this node has not acknowledged it yet.",
        fix: "Make sure the node is powered on and connected, then wait for acknowledgement or use Republish Config if it stays pending."
      }
    when "applied"
      {
        description: "The node acknowledged and applied the latest published config.",
        fix: "No action needed."
      }
    else
      {
        description: "No config status has been recorded for this node yet.",
        fix: "Republish config after the node is claimed and online."
      }
    end
  end

  def node_runtime_error_guidance(node)
    last_error = node.last_error.to_s

    case last_error
    when "", "none"
      {
        description: "The node has not reported a runtime error.",
        fix: "No action needed."
      }
    else
      issue_guidance_for(kind: :runtime_error, key: last_error, detail: last_error).merge(
        fix: issue_guidance_for(kind: :runtime_error, key: last_error, detail: last_error)[:fix] == DEFAULT_GUIDANCE[:fix] ?
          "Inspect the node details, confirm power and connectivity, then request a fresh reading or reboot the node if the error persists." :
          issue_guidance_for(kind: :runtime_error, key: last_error, detail: last_error)[:fix]
      )
    end
  end

  def reading_error_guidance(reading)
    last_error = reading&.last_error.to_s
    return { description: "The reading does not report an error.", fix: "No action needed." } if last_error.blank? || last_error == "none"

    issue_guidance_for(kind: :runtime_error, key: last_error, detail: last_error).merge(
      fix: issue_guidance_for(kind: :runtime_error, key: last_error, detail: last_error)[:fix] == DEFAULT_GUIDANCE[:fix] ?
        "Check the node that produced this reading, then compare the next fresh reading against the expected moisture condition." :
        issue_guidance_for(kind: :runtime_error, key: last_error, detail: last_error)[:fix]
    )
  end

  def actuator_fault_guidance(status)
    fault_code = status&.fault_code.to_s
    return { description: "The actuator status does not report a fault code.", fix: "No action needed." } if fault_code.blank?

    issue_guidance_for(kind: :fault_code, key: fault_code, detail: status&.fault_detail)
  end
end
