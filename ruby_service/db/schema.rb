# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_08_04_020000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "actuator_devices", force: :cascade do |t|
    t.string "logical_node_id", null: false
    t.string "device_uid"
    t.string "provisioning_operation_id"
    t.string "zone_external_id"
    t.string "board"
    t.string "firmware_kind", default: "actuator", null: false
    t.string "firmware_version"
    t.integer "irrigation_line_count"
    t.string "state", default: "pending_observation", null: false
    t.datetime "provisioned_at"
    t.datetime "last_seen_at"
    t.datetime "config_acknowledged_at"
    t.string "config_status"
    t.text "config_error"
    t.boolean "current", default: false, null: false
    t.datetime "superseded_at"
    t.string "supersession_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["current"], name: "idx_actuator_devices_one_current", unique: true, where: "current"
    t.index ["device_uid"], name: "idx_actuator_devices_unique_device_uid", unique: true, where: "(device_uid IS NOT NULL)"
    t.index ["logical_node_id"], name: "idx_actuator_devices_current_logical_node", unique: true, where: "current"
    t.index ["logical_node_id"], name: "idx_actuator_devices_logical_node"
    t.check_constraint "NOT current OR superseded_at IS NULL", name: "chk_actuator_devices_current_not_superseded"
    t.check_constraint "firmware_kind::text = 'actuator'::text", name: "chk_actuator_devices_firmware_kind"
    t.check_constraint "irrigation_line_count IS NULL OR irrigation_line_count > 0", name: "chk_actuator_devices_irrigation_line_count_positive"
    t.check_constraint "state::text = ANY (ARRAY['pending_observation'::character varying, 'observed'::character varying, 'configured'::character varying, 'ready'::character varying, 'stale'::character varying, 'conflict'::character varying, 'inactive'::character varying]::text[])", name: "chk_actuator_devices_state"
    t.check_constraint "superseded_at IS NULL OR NOT current", name: "chk_actuator_devices_superseded_not_current"
  end

  create_table "actuator_outputs", force: :cascade do |t|
    t.bigint "actuator_device_id", null: false
    t.integer "output_index", null: false
    t.string "state", default: "unknown", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actuator_device_id", "output_index"], name: "idx_actuator_outputs_device_output", unique: true
    t.index ["actuator_device_id"], name: "index_actuator_outputs_on_actuator_device_id"
    t.check_constraint "output_index > 0", name: "chk_actuator_outputs_output_index_positive"
    t.check_constraint "state::text = ANY (ARRAY['available'::character varying, 'assigned'::character varying, 'disabled'::character varying, 'faulted'::character varying, 'unknown'::character varying]::text[])", name: "chk_actuator_outputs_state"
  end

  create_table "actuator_statuses", force: :cascade do |t|
    t.bigint "zone_id", null: false
    t.string "state", null: false
    t.datetime "recorded_at", null: false
    t.string "idempotency_key"
    t.integer "actual_runtime_seconds"
    t.integer "flow_ml"
    t.string "fault_code"
    t.text "fault_detail"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "node_id"
    t.index ["idempotency_key", "state"], name: "index_actuator_statuses_on_idempotency_key_and_state_unique", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["node_id", "recorded_at"], name: "index_actuator_statuses_on_node_id_and_recorded_at"
    t.index ["zone_id", "recorded_at"], name: "index_actuator_statuses_on_zone_id_and_recorded_at"
    t.index ["zone_id"], name: "index_actuator_statuses_on_zone_id"
  end

  create_table "connection_settings", force: :cascade do |t|
    t.string "mqtt_host"
    t.integer "mqtt_port"
    t.string "readings_topic"
    t.string "actuators_topic"
    t.string "command_topic"
    t.string "config_topic"
    t.boolean "bluetooth_enabled", default: false, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "mqtt_username"
    t.string "mqtt_password"
    t.integer "irrigation_line_count"
  end

  create_table "crop_profiles", force: :cascade do |t|
    t.string "crop_id", null: false
    t.string "crop_name", null: false
    t.decimal "dry_threshold", precision: 5, scale: 2, null: false
    t.integer "max_pulse_runtime_sec", null: false
    t.integer "daily_max_runtime_sec", null: false
    t.text "notes"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "climate_preference"
    t.integer "time_to_harvest_days"
    t.index ["crop_id"], name: "index_crop_profiles_on_crop_id", unique: true
  end

  create_table "faults", force: :cascade do |t|
    t.bigint "zone_id"
    t.string "fault_code", null: false
    t.text "detail"
    t.datetime "recorded_at", null: false
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "node_id"
    t.index ["node_id", "recorded_at"], name: "index_faults_on_node_id_and_recorded_at"
    t.index ["zone_id", "recorded_at"], name: "index_faults_on_zone_id_and_recorded_at"
    t.index ["zone_id"], name: "index_faults_on_zone_id"
  end

  create_table "node_commands", force: :cascade do |t|
    t.bigint "zone_id", null: false
    t.string "node_id", null: false
    t.string "command", null: false
    t.string "command_id", null: false
    t.string "status", default: "queued", null: false
    t.datetime "issued_at", null: false
    t.datetime "acknowledged_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["command_id"], name: "index_node_commands_on_command_id", unique: true
    t.index ["node_id", "issued_at"], name: "index_node_commands_on_node_id_and_issued_at"
    t.index ["zone_id"], name: "index_node_commands_on_zone_id"
  end

  create_table "nodes", force: :cascade do |t|
    t.string "node_id", null: false
    t.bigint "zone_id"
    t.string "reported_zone_id"
    t.datetime "last_seen_at", null: false
    t.string "schema_version"
    t.boolean "provisioned", default: false, null: false
    t.decimal "battery_voltage", precision: 4, scale: 2
    t.integer "wifi_rssi"
    t.string "health"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "desired_config", default: {}, null: false
    t.jsonb "applied_config", default: {}, null: false
    t.string "config_version"
    t.string "config_status"
    t.datetime "config_published_at"
    t.datetime "config_acknowledged_at"
    t.text "config_error"
    t.integer "moisture_raw_dry"
    t.integer "moisture_raw_wet"
    t.string "device_id"
    t.string "name"
    t.bigint "crop_profile_id"
    t.integer "irrigation_line"
    t.index ["crop_profile_id"], name: "index_nodes_on_crop_profile_id"
    t.index ["device_id"], name: "index_nodes_on_device_id"
    t.index ["irrigation_line"], name: "index_nodes_on_irrigation_line", unique: true, where: "(irrigation_line IS NOT NULL)"
    t.index ["node_id"], name: "index_nodes_on_node_id", unique: true
    t.index ["zone_id"], name: "index_nodes_on_zone_id"
  end

  create_table "sensor_readings", force: :cascade do |t|
    t.bigint "zone_id", null: false
    t.string "node_id", null: false
    t.datetime "recorded_at", null: false
    t.integer "moisture_raw"
    t.decimal "moisture_percent", precision: 5, scale: 2
    t.decimal "battery_voltage", precision: 4, scale: 2
    t.integer "wifi_rssi"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "schema_version"
    t.decimal "soil_temp_c", precision: 5, scale: 2
    t.integer "battery_percent"
    t.bigint "uptime_seconds"
    t.bigint "wake_count"
    t.string "ip_address"
    t.string "health"
    t.text "last_error"
    t.string "publish_reason"
    t.jsonb "raw_payload", default: {}, null: false
    t.decimal "air_temperature_c", precision: 5, scale: 2
    t.decimal "humidity_percent", precision: 5, scale: 2
    t.boolean "soil_moisture_read", default: false, null: false
    t.string "greenhouse_alert_status", default: "normal", null: false
    t.index ["node_id", "recorded_at"], name: "index_sensor_readings_on_node_id_and_recorded_at"
    t.index ["zone_id", "recorded_at"], name: "index_sensor_readings_on_zone_id_and_recorded_at"
    t.index ["zone_id"], name: "index_sensor_readings_on_zone_id"
  end

  create_table "watering_events", force: :cascade do |t|
    t.bigint "zone_id", null: false
    t.string "command", null: false
    t.integer "runtime_seconds"
    t.string "reason"
    t.datetime "issued_at", null: false
    t.string "idempotency_key", null: false
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "node_id"
    t.boolean "setup_validation", default: false, null: false
    t.boolean "setup_current", default: false, null: false
    t.datetime "setup_superseded_at"
    t.string "setup_supersession_reason"
    t.datetime "setup_invalidated_at"
    t.string "setup_invalidation_reason"
    t.string "setup_target_kind"
    t.string "setup_target_zone_external_id"
    t.string "setup_target_node_id"
    t.integer "setup_target_irrigation_line"
    t.bigint "setup_target_crop_profile_id"
    t.string "setup_target_fingerprint"
    t.index ["idempotency_key"], name: "index_watering_events_on_idempotency_key", unique: true
    t.index ["node_id", "issued_at"], name: "index_watering_events_on_node_id_and_issued_at"
    t.index ["setup_current"], name: "idx_watering_events_one_current_setup_validation", unique: true, where: "(setup_validation AND setup_current)"
    t.index ["setup_target_fingerprint"], name: "idx_watering_events_setup_target_fingerprint", where: "setup_validation"
    t.index ["setup_validation", "setup_current"], name: "idx_watering_events_setup_current_lookup", where: "setup_validation"
    t.index ["setup_validation", "status", "issued_at"], name: "idx_watering_events_setup_status_issued_at", where: "setup_validation"
    t.index ["zone_id", "issued_at"], name: "index_watering_events_on_zone_id_and_issued_at"
    t.index ["zone_id", "status"], name: "index_watering_events_on_zone_id_and_status"
    t.index ["zone_id"], name: "index_watering_events_on_zone_id"
    t.check_constraint "NOT setup_current OR setup_validation", name: "chk_watering_events_setup_current_requires_validation"
    t.check_constraint "NOT setup_validation OR command::text = 'start_watering'::text", name: "chk_watering_events_setup_validation_start"
    t.check_constraint "NOT setup_validation OR setup_target_fingerprint IS NOT NULL", name: "chk_watering_events_setup_target_fingerprint"
    t.check_constraint "setup_target_kind IS NULL OR (setup_target_kind::text = ANY (ARRAY['zone'::character varying, 'node'::character varying]::text[]))", name: "chk_watering_events_setup_target_kind"
    t.check_constraint "setup_target_kind::text <> 'node'::text OR setup_target_node_id IS NOT NULL", name: "chk_watering_events_setup_node_target_has_node"
  end

  create_table "zones", force: :cascade do |t|
    t.string "zone_id", null: false
    t.bigint "crop_profile_id", null: false
    t.boolean "active", default: true, null: false
    t.jsonb "allowed_hours"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.integer "irrigation_line"
    t.integer "publish_interval_ms", default: 3600000, null: false
    t.index ["crop_profile_id"], name: "index_zones_on_crop_profile_id"
    t.index ["irrigation_line"], name: "index_zones_on_irrigation_line", unique: true, where: "(irrigation_line IS NOT NULL)"
    t.index ["zone_id"], name: "index_zones_on_zone_id", unique: true
  end

  add_foreign_key "actuator_outputs", "actuator_devices"
  add_foreign_key "actuator_statuses", "zones"
  add_foreign_key "faults", "zones"
  add_foreign_key "node_commands", "zones"
  add_foreign_key "nodes", "crop_profiles"
  add_foreign_key "nodes", "zones"
  add_foreign_key "sensor_readings", "zones"
  add_foreign_key "watering_events", "zones"
  add_foreign_key "zones", "crop_profiles"
end
