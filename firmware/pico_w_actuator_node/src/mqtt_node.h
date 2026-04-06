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
    node_config_t *config;
    bool config_changed_requires_reconnect;
    bool actuator_running;
    bool actuator_relay_enabled;
    bool actuator_status_pending;
    uint32_t actuator_started_at_ms;
    uint32_t actuator_runtime_seconds;
    absolute_time_t actuator_hard_deadline;
    actuator_status_t pending_actuator_status;
    char actuator_idempotency_key[96];
    char actuator_fault_code[32];
    char actuator_fault_detail[128];
    char last_error[128];
} mqtt_node_t;

void mqtt_node_init(mqtt_node_t *node, node_config_t *config);
void mqtt_node_poll(mqtt_node_t *node);
bool mqtt_node_is_connected(const mqtt_node_t *node);
bool mqtt_node_publish_canary(mqtt_node_t *node);
bool mqtt_node_take_reconnect_request(mqtt_node_t *node);
