#pragma once

#include <stddef.h>

#include "config.h"

void topic_actuator_command(const node_config_t *config, char *out, size_t out_size);
void topic_actuator_status(const node_config_t *config, char *out, size_t out_size);
void topic_node_config(const node_config_t *config, char *out, size_t out_size);
void topic_node_config_ack(const node_config_t *config, char *out, size_t out_size);
