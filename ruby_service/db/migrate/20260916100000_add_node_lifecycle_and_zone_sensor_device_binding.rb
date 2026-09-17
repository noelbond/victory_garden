class AddNodeLifecycleAndZoneSensorDeviceBinding < ActiveRecord::Migration[8.0]
  INDEX_NAME = "index_zones_on_sensor_device_id"

  def up
    add_column :nodes, :active, :boolean, default: true, null: false
    change_column_null :nodes, :last_seen_at, true

    add_column :zones, :sensor_device_id, :string
    backfill_unambiguous_sensor_device_bindings
    add_index :zones, :sensor_device_id, unique: true, where: "sensor_device_id IS NOT NULL", name: INDEX_NAME
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Node lifecycle and sensor-device bindings cannot be removed without risking logical topology data."
  end

  private

  def backfill_unambiguous_sensor_device_bindings
    execute <<~SQL
      -- This migration predates the runtime aggregate validations.  Bind only
      -- a package whose existing rows already prove the final invariant; do
      -- not infer ownership from partial or legacy discovery topology.
      WITH canonical_zone_packages AS (
        SELECT zone_id, MIN(device_id) AS package_id
        FROM nodes
        WHERE zone_id IS NOT NULL
        GROUP BY zone_id
        HAVING COUNT(*) = 4
          AND COUNT(device_id) = 4
          AND COUNT(DISTINCT device_id) = 1
          AND BOOL_AND(
            node_id = device_id || '-ch0' OR
            node_id = device_id || '-ch1' OR
            node_id = device_id || '-ch2' OR
            node_id = device_id || '-ch3'
          )
          -- Keep this migration-local so it remains stable without loading
          -- application models or future validations.
          AND BOOL_AND(
            octet_length(device_id) BETWEEN 1 AND 27
            AND device_id ~ '^[A-Za-z0-9_-]+$'
            AND device_id !~ '-ch[0-9]+$'
          )
      ), unambiguous_zone_packages AS (
        SELECT candidate.zone_id, candidate.package_id
        FROM canonical_zone_packages candidate
        WHERE NOT EXISTS (
          SELECT 1
          FROM nodes package_peer
          WHERE package_peer.device_id = candidate.package_id
            AND package_peer.zone_id IS DISTINCT FROM candidate.zone_id
        )
          AND NOT EXISTS (
            SELECT 1
            FROM zones bound_zone
            WHERE bound_zone.sensor_device_id = candidate.package_id
              AND bound_zone.id <> candidate.zone_id
          )
      )
      UPDATE zones
      SET sensor_device_id = unambiguous_zone_packages.package_id
      FROM unambiguous_zone_packages
      WHERE zones.id = unambiguous_zone_packages.zone_id
        AND zones.sensor_device_id IS NULL
        -- Do not promote an unsafe legacy Zone identity into a firmware-visible
        -- bound topology. Leave it unresolved for an explicit repair path.
        AND octet_length(zones.zone_id) BETWEEN 1 AND 31
        AND zones.zone_id ~ '^[A-Za-z0-9_-]+$'
    SQL
  end
end
