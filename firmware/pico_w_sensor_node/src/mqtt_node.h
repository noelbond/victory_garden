#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "config.h"
#include "pico/stdlib.h"
#include "sensors.h"

typedef struct {
    node_config_t *config;
    bool publish_requested;
    bool reboot_requested;
    bool config_changed_requires_reconnect;
    char last_error[128];
} mqtt_node_t;

void mqtt_node_init(mqtt_node_t *node, node_config_t *config);
void mqtt_node_poll(mqtt_node_t *node);
bool mqtt_node_is_connected(const mqtt_node_t *node);
bool mqtt_node_publish_canary(mqtt_node_t *node);
bool mqtt_node_publish_state(mqtt_node_t *node, const sensor_snapshot_t *snapshot, const char *reason);
bool mqtt_node_has_publish_request(const mqtt_node_t *node);
bool mqtt_node_take_publish_request(mqtt_node_t *node);
bool mqtt_node_take_reconnect_request(mqtt_node_t *node);
bool mqtt_node_take_reboot_request(mqtt_node_t *node);
void mqtt_node_mark_publish_request_handled(mqtt_node_t *node);
