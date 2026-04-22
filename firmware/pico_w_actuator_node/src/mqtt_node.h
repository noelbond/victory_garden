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
    uint8_t irrigation_line;
} actuator_zone_assignment_t;

typedef struct {
    bool running;
    char zone_id[VG_MAX_ZONE_ID_LEN];
    char idempotency_key[96];
    uint32_t started_at_ms;
    uint32_t runtime_seconds;
    absolute_time_t hard_deadline;
} actuator_line_run_t;

typedef struct {
    node_config_t *config;
    bool config_changed_requires_reconnect;
    uint8_t irrigation_line_count;
    actuator_zone_assignment_t assignments[VG_MAX_IRRIGATION_LINES];
    actuator_line_run_t runs[VG_MAX_IRRIGATION_LINES];
    bool relay_enabled[VG_MAX_IRRIGATION_LINES];
    char last_error[128];
} mqtt_node_t;

void mqtt_node_init(mqtt_node_t *node, node_config_t *config);
void mqtt_node_poll(mqtt_node_t *node);
bool mqtt_node_is_connected(const mqtt_node_t *node);
bool mqtt_node_publish_canary(mqtt_node_t *node);
bool mqtt_node_take_reconnect_request(mqtt_node_t *node);
