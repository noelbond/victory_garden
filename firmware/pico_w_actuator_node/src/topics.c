#include "topics.h"

#include <stdio.h>

void topic_actuator_command(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/zones/%s/actuator/command", config->zone_id);
}

void topic_actuator_status(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/zones/%s/actuator/status", config->zone_id);
}

void topic_node_config(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/nodes/%s/config", config->node_id);
}

void topic_node_config_ack(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/nodes/%s/config_ack", config->node_id);
}
