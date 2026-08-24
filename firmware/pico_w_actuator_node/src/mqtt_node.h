#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "config.h"
#include "pico/stdlib.h"

typedef enum {
    ACTUATOR_STATUS_NONE = 0,
    ACTUATOR_STATUS_ACKNOWLEDGED,
    ACTUATOR_STATUS_RUNNING,
    ACTUATOR_STATUS_COMPLETED,
    ACTUATOR_STATUS_STOPPED,
    ACTUATOR_STATUS_FAULT,
} actuator_status_t;

typedef struct {
    bool assigned;
    bool active;
    char zone_id[VG_MAX_ZONE_ID_LEN];
    char node_id[VG_MAX_NODE_ID_LEN];
    uint8_t irrigation_line;
} actuator_zone_assignment_t;

typedef struct {
    bool running;
    char zone_id[VG_MAX_ZONE_ID_LEN];
    char node_id[VG_MAX_NODE_ID_LEN];
    char idempotency_key[96];
    uint32_t started_at_ms;
    uint32_t runtime_seconds;
    absolute_time_t hard_deadline;
    // Independent hardware-timer backstop for hard_deadline: fires from an
    // alarm IRQ and cuts the relay even if the main loop is stuck (e.g.
    // blocked reconnecting Wi-Fi), so a valve can never stay open past its
    // runtime just because the poll loop isn't running. gpio/off_level are
    // snapshotted when the alarm is scheduled so the callback never touches
    // node/config from IRQ context.
    alarm_id_t cutoff_alarm_id;
    uint8_t cutoff_gpio;
    bool cutoff_off_level;
    volatile bool hardware_cutoff_fired;
} actuator_line_run_t;

typedef struct {
    node_config_t *config;
    bool config_changed_requires_reconnect;
    uint8_t irrigation_line_count;
    actuator_zone_assignment_t assignments[VG_MAX_IRRIGATION_LINES];
    actuator_line_run_t runs[VG_MAX_IRRIGATION_LINES];
    char last_error[128];
} mqtt_node_t;

// Drives every irrigation relay GPIO to its safe OFF level. Call this at the
// very top of main(), before any Wi-Fi/network setup, so a relay is never
// left undriven/floating during boot or a post-reboot reconnect — it does
// not touch mqtt_node_t and has no network dependency.
void actuator_relays_init_safe(const node_config_t *config);
void mqtt_node_init(mqtt_node_t *node, node_config_t *config);
void mqtt_node_poll(mqtt_node_t *node);
void mqtt_node_disconnect(mqtt_node_t *node);
bool mqtt_node_is_connected(const mqtt_node_t *node);
bool mqtt_node_publish_canary(mqtt_node_t *node);
bool mqtt_node_take_reconnect_request(mqtt_node_t *node);
