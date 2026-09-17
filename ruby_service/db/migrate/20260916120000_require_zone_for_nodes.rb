class RequireZoneForNodes < ActiveRecord::Migration[8.0]
  def up
    unassigned = execute(<<~SQL)
      SELECT id, device_id
      FROM nodes
      WHERE zone_id IS NULL
      ORDER BY id
    SQL

    unassigned.each do |node|
      zone_ids = if node["device_id"].present?
        select_values(<<~SQL.squish)
          SELECT id FROM zones
          WHERE sensor_device_id = #{connection.quote(node["device_id"])}
        SQL
      else
        []
      end

      if zone_ids.one?
        execute(<<~SQL.squish)
          UPDATE nodes
          SET zone_id = #{connection.quote(zone_ids.first)}, updated_at = #{connection.quote(Time.current)}
          WHERE id = #{connection.quote(node["id"])} AND zone_id IS NULL
        SQL
      else
        # Legacy lazy discovery never persisted readings for unassigned Nodes.
        # Delete only the unresolved registry record rather than guessing a
        # routing authority; any historical reading remains intact by node_id.
        execute("DELETE FROM nodes WHERE id = #{connection.quote(node["id"])} AND zone_id IS NULL")
      end
    end

    change_column_null :nodes, :zone_id, false
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "unresolved legacy Nodes were deliberately removed rather than assigned to a guessed Zone"
  end
end
