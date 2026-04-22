#include "topics.h"

#include <stdio.h>

void topic_state(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/zones/%s/nodes/%s/state", config->zone_id, config->node_id);
}

void topic_command(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/zones/%s/command", config->zone_id);
}

void topic_command_ack(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/zones/%s/command_ack", config->zone_id);
}

void topic_node_config(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/nodes/%s/config", config->node_id);
}

void topic_node_config_ack(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/nodes/%s/config_ack", config->node_id);
}
