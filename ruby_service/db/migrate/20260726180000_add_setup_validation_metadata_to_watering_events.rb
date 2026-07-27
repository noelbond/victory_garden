class AddSetupValidationMetadataToWateringEvents < ActiveRecord::Migration[8.0]
  def change
    change_table :watering_events, bulk: true do |t|
      t.boolean :setup_validation, null: false, default: false
      t.boolean :setup_current, null: false, default: false
      t.datetime :setup_superseded_at
      t.string :setup_supersession_reason
      t.datetime :setup_invalidated_at
      t.string :setup_invalidation_reason
      t.string :setup_target_kind
      t.string :setup_target_zone_external_id
      t.string :setup_target_node_id
      t.integer :setup_target_irrigation_line
      t.bigint :setup_target_crop_profile_id
      t.string :setup_target_fingerprint
    end

    add_index :watering_events,
              :setup_current,
              unique: true,
              where: "setup_validation AND setup_current",
              name: "idx_watering_events_one_current_setup_validation"
    add_index :watering_events,
              [:setup_validation, :setup_current],
              where: "setup_validation",
              name: "idx_watering_events_setup_current_lookup"
    add_index :watering_events,
              [:setup_validation, :status, :issued_at],
              where: "setup_validation",
              name: "idx_watering_events_setup_status_issued_at"
    add_index :watering_events,
              :setup_target_fingerprint,
              where: "setup_validation",
              name: "idx_watering_events_setup_target_fingerprint"

    add_check_constraint :watering_events,
                         "NOT setup_current OR setup_validation",
                         name: "chk_watering_events_setup_current_requires_validation"
    add_check_constraint :watering_events,
                         "NOT setup_validation OR command = 'start_watering'",
                         name: "chk_watering_events_setup_validation_start"
    add_check_constraint :watering_events,
                         "setup_target_kind IS NULL OR setup_target_kind IN ('zone', 'node')",
                         name: "chk_watering_events_setup_target_kind"
    add_check_constraint :watering_events,
                         "setup_target_kind <> 'node' OR setup_target_node_id IS NOT NULL",
                         name: "chk_watering_events_setup_node_target_has_node"
    add_check_constraint :watering_events,
                         "NOT setup_validation OR setup_target_fingerprint IS NOT NULL",
                         name: "chk_watering_events_setup_target_fingerprint"
  end
end
