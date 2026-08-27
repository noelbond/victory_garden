#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "config.h"
#include "sensors.h"

bool sensor_state_payload_format(
    char *out,
    size_t out_size,
    const node_config_t *config,
    const sensor_snapshot_t *snapshot,
    const char *timestamp,
    const char *publish_node_id,
    const char *reason,
    uint32_t wake_count,
    uint32_t uptime_seconds,
    int32_t wifi_rssi,
    const char *ip,
    const char *last_error
);
