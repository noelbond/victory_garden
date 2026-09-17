class SensorZoneProvisioner
  CHANNELS = (0...Node::EXPECTED_CHANNELS_PER_DEVICE).freeze
  ADVISORY_LOCK_KEY = 66_001_066

  class ProvisioningError < StandardError; end

  def self.call(zone:, sensor_device_id:)
    new(zone:, sensor_device_id:).call
  end

  def initialize(zone:, sensor_device_id:)
    @zone = zone
    @sensor_device_id = sensor_device_id.to_s
  end

  def call
    raise ProvisioningError, "Sensor device identity is required." if @sensor_device_id.blank?
    if @sensor_device_id.match?(/-ch\d+\z/)
      raise ProvisioningError, "Sensor device identity must not include a channel suffix."
    end
    SensorIdentityContract.validate_provisioning!(zone_id: @zone.zone_id, package_id: @sensor_device_id)

    with_unique_retry do
      Zone.transaction do
        acquire_installation_lock!
        zone = Zone.lock.find(@zone.id)
        validate_target_zone_topology!(zone)
        validate_existing_package_topology!(zone)
        Zone.with_sensor_package_mutation do
          provision_channels!(zone)
          validate_final_zone_topology!(zone)
          bind_package!(zone)
        end
        zone
      end
    end
  rescue SensorIdentityContract::InvalidIdentity => error
    raise ProvisioningError, error.message
  end

  private

  def acquire_installation_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY})")
  end

  def bind_package!(zone)
    if zone.sensor_device_id.present? && zone.sensor_device_id != @sensor_device_id
      raise ProvisioningError, "Zone #{zone.zone_id} is already bound to #{zone.sensor_device_id}."
    end

    other_zone = Zone.where(sensor_device_id: @sensor_device_id).where.not(id: zone.id).first
    raise ProvisioningError, "Sensor device #{@sensor_device_id} is already bound to #{other_zone.zone_id}." if other_zone

    return if zone.sensor_device_id == @sensor_device_id

    zone.update!(sensor_device_id: @sensor_device_id)
  end

  def expected_node_ids
    CHANNELS.map { |channel| node_id_for(channel) }
  end

  def validate_target_zone_topology!(zone)
    # The Zone row lock prevents a concurrent Node insert or zone move from
    # acquiring the foreign-key lock it needs until this transaction commits.
    # Lock current rows too, then reject rather than deleting/moving legacy
    # topology that does not belong to this exact package.
    zone_nodes = zone.nodes.order(:id).lock.to_a
    unexpected = zone_nodes.find do |node|
      !expected_node_ids.include?(node.node_id) || node.device_id != @sensor_device_id
    end
    return unless unexpected

    raise ProvisioningError,
          "Zone #{zone.zone_id} contains unrelated node #{unexpected.node_id}; provision only an empty or matching four-channel package Zone."
  end

  def validate_existing_package_topology!(zone)
    expected_ids = expected_node_ids
    existing_package_nodes = Node.where(device_id: @sensor_device_id).order(:id).lock.to_a
    unexpected = existing_package_nodes.reject { |node| expected_ids.include?(node.node_id) }
    raise ProvisioningError, "Sensor device #{@sensor_device_id} has malformed channel identities." if unexpected.any?

    nodes = Node.where(node_id: expected_ids).order(:id).lock.to_a
    conflicting = nodes.find { |node| node.device_id.present? && node.device_id != @sensor_device_id }
    raise ProvisioningError, "Node #{conflicting.node_id} belongs to another sensor device." if conflicting
    wrong_zone = nodes.find { |node| node.zone_id != zone.id }
    raise ProvisioningError, "Node #{wrong_zone.node_id} is assigned to another zone." if wrong_zone
  end

  def provision_channels!(zone)
    expected_ids = expected_node_ids
    nodes = Node.where(node_id: expected_ids).to_a

    assigned_lines = Node.where.not(irrigation_line: nil).pluck(:irrigation_line)
    available_lines = lowest_available_lines(assigned_lines, CHANNELS.size - nodes.count { |node| node.irrigation_line.present? })

    CHANNELS.each do |channel|
      node_id = node_id_for(channel)
      node = Node.find_by(node_id: node_id)
      if node
        attributes = { zone: zone, device_id: @sensor_device_id, active: true }
        attributes[:irrigation_line] = available_lines.shift if node.irrigation_line.blank?
        node.update!(attributes)
      else
        Node.create!(
          node_id: node_id,
          device_id: @sensor_device_id,
          zone: zone,
          irrigation_line: available_lines.shift,
          active: true,
          last_seen_at: nil,
          crop_profile: nil
        )
      end
    end

    zone
  end

  def validate_final_zone_topology!(zone)
    final_nodes = zone.nodes.order(:node_id).lock.to_a
    expected_ids = expected_node_ids
    return if final_nodes.map(&:node_id) == expected_ids && final_nodes.all? { |node| node.device_id == @sensor_device_id }

    raise ProvisioningError,
          "Zone #{zone.zone_id} did not resolve to exactly the expected four channels for #{@sensor_device_id}."
  end

  def lowest_available_lines(assigned_lines, count)
    lines = []
    candidate = 1
    while lines.length < count
      lines << candidate unless assigned_lines.include?(candidate)
      candidate += 1
    end
    lines
  end

  def node_id_for(channel)
    "#{@sensor_device_id}-ch#{channel}"
  end

  def with_unique_retry
    yield
  rescue ActiveRecord::RecordNotUnique
    @unique_attempts ||= 0
    @unique_attempts += 1
    retry if @unique_attempts < 3
    raise
  end
end
