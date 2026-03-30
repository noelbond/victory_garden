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

ActiveRecord::Schema[8.0].define(version: 2026_03_24_000100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.bigint "zone_id", null: false
    t.string "fault_code", null: false
    t.text "detail"
    t.datetime "recorded_at", null: false
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["zone_id", "recorded_at"], name: "index_faults_on_zone_id_and_recorded_at"
    t.index ["zone_id"], name: "index_faults_on_zone_id"
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
    t.index ["node_id"], name: "index_nodes_on_node_id", unique: true
    t.index ["zone_id"], name: "index_nodes_on_zone_id"
  end

  create_table "sensor_readings", force: :cascade do |t|
    t.bigint "zone_id", null: false
    t.string "node_id", null: false
    t.datetime "recorded_at", null: false
    t.integer "moisture_raw", null: false
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
    t.index ["idempotency_key"], name: "index_watering_events_on_idempotency_key", unique: true
    t.index ["zone_id", "issued_at"], name: "index_watering_events_on_zone_id_and_issued_at"
    t.index ["zone_id"], name: "index_watering_events_on_zone_id"
  end

  create_table "zones", force: :cascade do |t|
    t.string "zone_id", null: false
    t.bigint "crop_profile_id", null: false
    t.boolean "active", default: true, null: false
    t.jsonb "allowed_hours"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.index ["crop_profile_id"], name: "index_zones_on_crop_profile_id"
    t.index ["zone_id"], name: "index_zones_on_zone_id", unique: true
  end

  add_foreign_key "actuator_statuses", "zones"
  add_foreign_key "faults", "zones"
  add_foreign_key "nodes", "zones"
  add_foreign_key "sensor_readings", "zones"
  add_foreign_key "watering_events", "zones"
  add_foreign_key "zones", "crop_profiles"
end
