#pragma once

#include <stddef.h>

#include "config.h"

void topic_state(const node_config_t *config, char *out, size_t out_size);
void topic_command(const node_config_t *config, char *out, size_t out_size);
void topic_command_ack(const node_config_t *config, char *out, size_t out_size);
void topic_node_config(const node_config_t *config, char *out, size_t out_size);
void topic_node_config_ack(const node_config_t *config, char *out, size_t out_size);
