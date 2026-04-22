#include "topics.h"

#include <stdio.h>

void topic_actuator_command_pattern(char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/zones/+/actuator/command");
}

void topic_actuator_command_for_zone(const char *zone_id, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/zones/%s/actuator/command", zone_id);
}

void topic_actuator_status_for_zone(const char *zone_id, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/zones/%s/actuator/status", zone_id);
}

void topic_actuator_system_config(char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/system/actuator/config/current");
}

void topic_node_config(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/nodes/%s/config", config->node_id);
}

void topic_node_config_ack(const node_config_t *config, char *out, size_t out_size) {
    snprintf(out, out_size, "greenhouse/nodes/%s/config_ack", config->node_id);
}
