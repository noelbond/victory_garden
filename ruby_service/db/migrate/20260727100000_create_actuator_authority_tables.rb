class CreateActuatorAuthorityTables < ActiveRecord::Migration[8.0]
  def change
    create_table :actuator_devices do |t|
      t.string :logical_node_id, null: false
      t.string :device_uid
      t.string :provisioning_operation_id
      t.string :zone_external_id
      t.string :board
      t.string :firmware_kind, null: false, default: "actuator"
      t.string :firmware_version
      t.integer :irrigation_line_count
      t.string :state, null: false, default: "pending_observation"
      t.datetime :provisioned_at
      t.datetime :last_seen_at
      t.datetime :config_acknowledged_at
      t.string :config_status
      t.text :config_error
      t.boolean :current, null: false, default: false
      t.datetime :superseded_at
      t.string :supersession_reason

      t.timestamps
    end

    add_index :actuator_devices,
              :current,
              unique: true,
              where: "current",
              name: "idx_actuator_devices_one_current"
    add_index :actuator_devices,
              :logical_node_id,
              name: "idx_actuator_devices_logical_node"
    add_index :actuator_devices,
              :logical_node_id,
              unique: true,
              where: "current",
              name: "idx_actuator_devices_current_logical_node"
    add_index :actuator_devices,
              :device_uid,
              unique: true,
              where: "device_uid IS NOT NULL",
              name: "idx_actuator_devices_unique_device_uid"

    add_check_constraint :actuator_devices,
                         "firmware_kind = 'actuator'",
                         name: "chk_actuator_devices_firmware_kind"
    add_check_constraint :actuator_devices,
                         "state IN ('pending_observation', 'observed', 'configured', 'ready', 'stale', 'conflict', 'inactive')",
                         name: "chk_actuator_devices_state"
    add_check_constraint :actuator_devices,
                         "irrigation_line_count IS NULL OR irrigation_line_count > 0",
                         name: "chk_actuator_devices_irrigation_line_count_positive"
    add_check_constraint :actuator_devices,
                         "NOT current OR superseded_at IS NULL",
                         name: "chk_actuator_devices_current_not_superseded"
    add_check_constraint :actuator_devices,
                         "superseded_at IS NULL OR NOT current",
                         name: "chk_actuator_devices_superseded_not_current"

    create_table :actuator_outputs do |t|
      t.references :actuator_device, null: false, foreign_key: true
      t.integer :output_index, null: false
      t.string :state, null: false, default: "unknown"

      t.timestamps
    end

    add_index :actuator_outputs,
              [:actuator_device_id, :output_index],
              unique: true,
              name: "idx_actuator_outputs_device_output"

    add_check_constraint :actuator_outputs,
                         "output_index > 0",
                         name: "chk_actuator_outputs_output_index_positive"
    add_check_constraint :actuator_outputs,
                         "state IN ('available', 'assigned', 'disabled', 'faulted', 'unknown')",
                         name: "chk_actuator_outputs_state"
  end
end
