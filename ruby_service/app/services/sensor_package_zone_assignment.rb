class SensorPackageZoneAssignment
  class AssignmentError < StandardError; end

  def self.call(node:, zone:)
    new(node:, zone:).call
  end

  def initialize(node:, zone:)
    @node = node
    @zone = zone
  end

  def call
    return assign_standalone_node unless @node.device_id.present?

    assign_existing_package
  end

  private

  def assign_standalone_node
    @node.update!(zone: @zone)
    @node
  end

  def assign_existing_package
    package_id = @node.device_id

    Node.transaction do
      target_zone = Zone.lock.find(@zone.id)
      package_nodes = Node.where(device_id: package_id).order(:id).lock.to_a
      raise AssignmentError, "Sensor package #{package_id} has no registered channels." if package_nodes.empty?

      SensorIdentityContract.validate_provisioning!(zone_id: target_zone.zone_id, package_id: package_id)
      validate_canonical_package!(package_id, package_nodes)

      if target_zone.sensor_device_id.present? && target_zone.sensor_device_id != package_id
        raise AssignmentError,
              "Zone #{target_zone.zone_id} is already bound to sensor package #{target_zone.sensor_device_id}."
      end

      other_package_node = target_zone.nodes.where.not(device_id: [nil, package_id]).lock.first
      if other_package_node
        raise AssignmentError,
              "Zone #{target_zone.zone_id} already owns sensor package #{other_package_node.device_id}."
      end

      package_zone_ids = package_nodes.map(&:zone_id).uniq
      if package_zone_ids.any? { |zone_id| zone_id != target_zone.id }
        raise AssignmentError,
              "Sensor package #{package_id} is already assigned to another Zone; individual channel reassignment is not allowed."
      end

      other_binding = Zone.where(sensor_device_id: package_id).where.not(id: target_zone.id).lock.first
      if other_binding
        raise AssignmentError, "Sensor package #{package_id} is already bound to #{other_binding.zone_id}."
      end

      if target_zone.sensor_device_id.blank?
        Zone.with_sensor_package_mutation do
          target_zone.update!(sensor_device_id: package_id)
        end
      end
      @node.reload
    end
  rescue ActiveRecord::RecordInvalid => e
    raise AssignmentError, e.record.errors.full_messages.to_sentence
  rescue SensorIdentityContract::InvalidIdentity => e
    raise AssignmentError, e.message
  end

  def validate_canonical_package!(package_id, package_nodes)
    expected_node_ids = Node.canonical_package_node_ids(package_id)
    return if package_nodes.map(&:node_id).sort == expected_node_ids && package_nodes.all? { |node| node.device_id == package_id }

    raise AssignmentError, "Sensor package #{package_id} must contain exactly its canonical four channels before assignment."
  end
end
