require "open3"

module VgCli
  class Runner
    SERVICE_ALIASES = {
      "web" => "victory-garden-web.service",
      "controller" => "greenhouse.service",
      "mqtt" => "victory-garden-mqtt-consumer.service",
      "discovery" => "victory-garden-mqtt-discovery.service",
      "broker" => "mosquitto.service"
    }.freeze

    STATUS_UNITS = SERVICE_ALIASES.merge("postgres" => "postgresql.service").freeze

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      command, *rest = argv

      case command
      when nil, "help", "-h", "--help"
        print_help
      when "zones"
        zones(rest)
      when "nodes"
        nodes(rest)
      when "readings"
        readings(rest)
      when "watering-events"
        watering_events(rest)
      when "faults"
        faults(rest)
      when "status"
        status(rest)
      when "net"
        net(rest)
      when "logs"
        logs(rest)
      when "mqtt"
        mqtt(rest)
      else
        puts "Unknown command: #{command}"
        print_help
        exit 1
      end
    end

    private

    # ---- data commands ----------------------------------------------------

    def zones(args)
      case args.first
      when "list", nil
        rows = Zone.order(:zone_id).map do |z|
          [z.zone_id, z.name.presence || "—", z.nodes.count, z.crop_profile&.crop_name || "—"]
        end
        Table.print(%w[zone_id name node_count crop_profile], rows)
      when "show"
        zone = find_zone!(args[1])
        return unless zone

        puts "zone_id:           #{zone.zone_id}"
        puts "name:              #{zone.name || "—"}"
        puts "crop_profile:      #{zone.crop_profile&.crop_name || "—"}"
        puts "publish_interval:  #{zone.reading_frequency_hours}h"
        puts "allowed_hours:     #{zone.allowed_hours.inspect}"
        puts "irrigation_line:   #{zone.irrigation_line || "—"}"
        puts "nodes:             #{zone.nodes.count}"
      else
        puts "Usage: vg zones list | vg zones show <zone_id>"
      end
    end

    def nodes(args)
      case args.first
      when "list", nil
        opts = extract_options(args[1..], "--zone")
        scope = Node.order(:node_id)
        if opts["--zone"]
          zone = find_zone!(opts["--zone"])
          return unless zone

          scope = scope.where(zone_id: zone.id)
        end
        rows = scope.map do |n|
          [n.node_id, n.display_name, n.zone&.zone_id || "unassigned", n.health || "—", staleness(n.last_seen_at)]
        end
        Table.print(%w[node_id name zone health last_seen], rows)
      when "show"
        node = find_node!(args[1])
        return unless node

        latest = node.latest_sensor_reading
        puts "node_id:          #{node.node_id}"
        puts "name:             #{node.display_name}"
        puts "zone:             #{node.zone&.zone_id || "unassigned"}"
        puts "device_id:        #{node.device_id || "—"}"
        puts "health:           #{node.health || "—"}"
        puts "last_error:       #{node.last_error.presence || "none"}"
        puts "last_seen_at:     #{node.last_seen_at&.utc} (#{staleness(node.last_seen_at)})"
        puts "wifi_rssi:        #{node.wifi_rssi || "—"}"
        puts "battery_voltage:  #{node.battery_voltage || "—"}"
        puts "config_status:    #{node.config_status || "—"}"
        puts "ip_address:       #{latest&.ip_address || "—"}"
      else
        puts "Usage: vg nodes list [--zone <zone_id>] | vg nodes show <node_id>"
      end
    end

    def readings(args)
      opts = extract_options(args, "--zone", "--node", "--limit")
      scope = SensorReading.order(recorded_at: :desc)

      if opts["--zone"] && opts["--zone"] != "all"
        zone = find_zone!(opts["--zone"])
        return unless zone

        scope = scope.where(zone_id: zone.id)
      end

      if opts["--node"] && opts["--node"] != "all"
        scope = scope.where(node_id: opts["--node"])
      end

      limit = (opts["--limit"] || "20").to_i
      rows = scope.limit(limit).includes(:zone).map do |r|
        [
          r.recorded_at.utc.strftime("%Y-%m-%d %H:%M:%S"),
          r.zone&.zone_id || "—",
          r.node_id,
          r.moisture_percent.nil? ? "—" : "#{r.moisture_percent}%",
          r.soil_temp_c || "—",
          r.wifi_rssi || "—",
          r.health || "—",
          r.publish_reason || "—"
        ]
      end
      Table.print(%w[recorded_at zone node moisture soil_temp_c rssi health reason], rows)
    end

    def watering_events(args)
      opts = extract_options(args, "--zone", "--node", "--limit")
      scope = WateringEvent.order(issued_at: :desc)

      if opts["--zone"] && opts["--zone"] != "all"
        zone = find_zone!(opts["--zone"])
        return unless zone

        scope = scope.where(zone_id: zone.id)
      end

      scope = scope.where(node_id: opts["--node"]) if opts["--node"] && opts["--node"] != "all"

      limit = (opts["--limit"] || "20").to_i
      rows = scope.limit(limit).includes(:zone).map do |e|
        [
          e.issued_at.utc.strftime("%Y-%m-%d %H:%M:%S"),
          e.zone&.zone_id || "—",
          e.node_id || "—",
          e.command,
          e.status,
          e.runtime_seconds || "—"
        ]
      end
      Table.print(%w[issued_at zone node command status runtime_sec], rows)
    end

    def faults(_args)
      rows = Fault.where(resolved_at: nil).order(recorded_at: :desc).includes(:zone).map do |f|
        [f.recorded_at.utc.strftime("%Y-%m-%d %H:%M:%S"), f.zone&.zone_id || "—", f.node_id || "—", f.fault_code]
      end
      Table.print(%w[recorded_at zone node fault_code], rows)
    end

    # ---- status -------------------------------------------------------------

    def status(_args)
      rows = STATUS_UNITS.map do |alias_name, unit|
        active, sub, restarts = systemctl_show(unit)
        [alias_name, unit, active, sub, restarts]
      end
      Table.print(%w[service unit active sub restarts], rows)

      status_path = Rails.root.join("tmp/mqtt_consumer_status.json")
      return unless File.exist?(status_path)

      data = JSON.parse(File.read(status_path))
      puts
      puts "mqtt_consumer: connected=#{data["connected"]} status=#{data["status"]} retry_count=#{data["retry_count"]} last_error=#{data["last_error"] || "none"}"
    rescue JSON::ParserError
      nil
    end

    def systemctl_show(unit)
      out, = Open3.capture2("systemctl", "show", unit, "-p", "ActiveState", "-p", "SubState", "-p", "NRestarts")
      values = out.each_line.each_with_object({}) do |line, acc|
        key, value = line.strip.split("=", 2)
        acc[key] = value
      end
      [values["ActiveState"] || "unknown", values["SubState"] || "unknown", values["NRestarts"] || "—"]
    end

    # ---- network --------------------------------------------------------

    def net(args)
      case args.first
      when "pi"
        net_pi
      when "nodes"
        net_nodes
      when "stale"
        net_stale(args[1..])
      when "ping"
        net_ping(args[1])
      when "broker"
        net_broker
      when "discovery"
        net_discovery
      else
        puts "Usage: vg net pi | nodes | stale [--minutes N] | ping <node_id> | broker | discovery"
      end
    end

    def net_pi
      iface = ENV.fetch("VG_WIFI_INTERFACE", "wlan0")
      puts "interface: #{iface}"
      out, = Open3.capture2("hostname", "-I")
      puts "ip:        #{out.strip}"
      link_out, link_status = Open3.capture2("iw", "dev", iface, "link")
      if link_status.success?
        puts link_out
      else
        puts "iw dev #{iface} link failed (no wifi interface, or iw not installed)"
      end
    end

    def net_nodes
      rows = Node.order(:node_id).map do |n|
        latest = n.latest_sensor_reading
        [n.node_id, n.display_name, latest&.ip_address || "—", n.wifi_rssi || "—", staleness(n.last_seen_at)]
      end
      Table.print(%w[node_id name ip_address rssi last_seen], rows)
    end

    def net_stale(args)
      opts = extract_options(args, "--minutes")
      threshold = (opts["--minutes"] || "60").to_i.minutes
      rows = Node.where("last_seen_at < ?", threshold.ago).order(:last_seen_at).map do |n|
        [n.node_id, n.display_name, n.zone&.zone_id || "unassigned", staleness(n.last_seen_at)]
      end
      Table.print(%w[node_id name zone last_seen], rows)
    end

    def net_ping(node_id)
      node = find_node!(node_id)
      return unless node

      ip = node.latest_sensor_reading&.ip_address
      unless ip
        puts "No known ip_address for #{node_id} (no readings yet)"
        return
      end

      puts "Pinging #{node_id} at #{ip}..."
      system("ping", "-c", "4", ip)
    end

    def net_broker
      require "mqtt"
      settings = ConnectionSetting.first
      host = settings&.mqtt_host.presence || ENV.fetch("MQTT_HOST", "localhost")
      port = Integer(settings&.mqtt_port.presence || ENV.fetch("MQTT_PORT", "1883"))
      username = settings&.mqtt_username.presence || ENV["MQTT_USERNAME"]
      password = settings&.mqtt_password.presence || ENV["MQTT_PASSWORD"]

      puts "Connecting to #{host}:#{port} as #{username || "(no username)"}..."
      client = MQTT::Client.connect(host: host, port: port, username: username, password: password, connect_timeout: 5)
      client.disconnect
      puts "OK: broker connection and auth succeeded."
    rescue StandardError => e
      puts "FAILED: #{e.class}: #{e.message}"
    end

    def net_discovery
      active, sub, restarts = systemctl_show(SERVICE_ALIASES.fetch("discovery"))
      puts "service: #{active}/#{sub} (restarts=#{restarts})"

      port = ENV.fetch("MQTT_DISCOVERY_PORT", "44737")
      out, = Open3.capture2("ss", "-uln")
      listening = out.lines.any? { |line| line.include?(":#{port}") }
      puts "udp port #{port}: #{listening ? "listening" : "NOT listening"}"
    end

    # ---- logs -------------------------------------------------------------

    def logs(args)
      opts = extract_options(args, "-n")
      name = args.reject { |a| a.start_with?("-") }.first
      unit = SERVICE_ALIASES[name]
      unless unit
        puts "Unknown service '#{name}'. Known: #{SERVICE_ALIASES.keys.join(", ")}"
        return
      end

      lines = opts["-n"] || "50"
      system("journalctl", "-u", unit, "-n", lines, "--no-pager")
    end

    # ---- mqtt ---------------------------------------------------------------

    def mqtt(args)
      case args.first
      when "watch", nil
        mqtt_watch(args[1..] || [])
      else
        puts "Usage: vg mqtt watch [--zone <zone_id>] [--node <node_id>]"
      end
    end

    def mqtt_watch(args)
      opts = extract_options(args, "--zone", "--node")
      zone = opts["--zone"] || "+"
      node = opts["--node"] || "+"
      topic = "greenhouse/zones/#{zone}/nodes/#{node}/state"
      topic = "greenhouse/#" if opts.empty?

      host = ENV.fetch("MQTT_HOST", "localhost")
      port = ENV.fetch("MQTT_PORT", "1883")
      username = ENV["MQTT_USERNAME"]
      password = ENV["MQTT_PASSWORD"]

      cmd = ["mosquitto_sub", "-h", host, "-p", port, "-t", topic, "-v"]
      cmd += ["-u", username, "-P", password] if username && password

      puts "Subscribing to #{topic} on #{host}:#{port} (Ctrl+C to stop)..."
      $stdout.flush
      exec(*cmd)
    end

    # ---- shared helpers -----------------------------------------------------

    def find_zone!(zone_id)
      zone = Zone.find_by(zone_id: zone_id)
      puts "No zone found with zone_id=#{zone_id}" unless zone
      zone
    end

    def find_node!(node_id)
      node = Node.find_by(node_id: node_id)
      puts "No node found with node_id=#{node_id}" unless node
      node
    end

    def staleness(time)
      return "never" if time.nil?

      seconds = (Time.current - time).to_i
      return "#{seconds}s ago" if seconds < 60
      return "#{seconds / 60}m ago" if seconds < 3600
      return "#{seconds / 3600}h ago" if seconds < 86_400

      "#{seconds / 86_400}d ago"
    end

    def extract_options(args, *keys)
      result = {}
      remaining = args.dup
      keys.each do |key|
        index = remaining.index(key)
        next unless index

        result[key] = remaining[index + 1]
        remaining.slice!(index, 2)
      end
      result
    end

    def print_help
      puts <<~HELP
        vg — Victory Garden operator CLI

        Data:
          vg zones list
          vg zones show <zone_id>
          vg nodes list [--zone <zone_id>]
          vg nodes show <node_id>
          vg readings [--zone <zone_id>|all] [--node <node_id>|all] [--limit N]
          vg watering-events [--zone <zone_id>|all] [--node <node_id>|all] [--limit N]
          vg faults

        Status:
          vg status

        Network:
          vg net pi
          vg net nodes
          vg net stale [--minutes N]
          vg net ping <node_id>
          vg net broker
          vg net discovery

        Logs (journalctl, most recent first):
          vg logs <web|controller|mqtt|discovery|broker> [-n N]

        Live MQTT:
          vg mqtt watch [--zone <zone_id>] [--node <node_id>]

        Help:
          vg help
      HELP
    end
  end
end
