#pragma once

#include <stddef.h>

#include "config.h"

void topic_actuator_command_pattern(char *out, size_t out_size);
void topic_actuator_command_for_zone(const char *zone_id, char *out, size_t out_size);
void topic_actuator_status_for_zone(const char *zone_id, char *out, size_t out_size);
void topic_actuator_system_config(char *out, size_t out_size);
void topic_node_config(const node_config_t *config, char *out, size_t out_size);
void topic_node_config_ack(const node_config_t *config, char *out, size_t out_size);
