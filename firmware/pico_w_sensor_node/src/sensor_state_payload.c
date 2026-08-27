#include "sensor_state_payload.h"

#include <stdio.h>

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
) {
    char soil_fields[128];
    char environment_fields[160];
    char ip_field[80];

    if (!out || out_size == 0 || !config || !snapshot || !timestamp || !publish_node_id || !reason) {
        return false;
    }

    if (snapshot->soil_moisture_read) {
        snprintf(
            soil_fields,
            sizeof(soil_fields),
            "\"moisture_raw\":%u,\"moisture_percent\":%d,\"soil_moisture_read\":true",
            snapshot->moisture_raw,
            snapshot->moisture_percent
        );
    } else {
        snprintf(
            soil_fields,
            sizeof(soil_fields),
            "\"moisture_raw\":null,\"moisture_percent\":null,\"soil_moisture_read\":false"
        );
    }

    if (snapshot->environment_valid) {
        snprintf(
            environment_fields,
            sizeof(environment_fields),
            "\"air_temperature_c\":%.2f,\"humidity_percent\":%.2f",
            (double)snapshot->air_temperature_c,
            (double)snapshot->humidity_percent
        );
    } else {
        snprintf(
            environment_fields,
            sizeof(environment_fields),
            "\"air_temperature_c\":null,\"humidity_percent\":null"
        );
    }

    if (ip && ip[0] != '\0') {
        snprintf(ip_field, sizeof(ip_field), "\"ip\":\"%s\"", ip);
    } else {
        snprintf(ip_field, sizeof(ip_field), "\"ip\":null");
    }

    int written = snprintf(
        out,
        out_size,
        "{\"schema_version\":\"node-state/v1\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"device_id\":\"%s\",%s,%s,\"soil_temp_c\":null,\"battery_voltage\":null,\"battery_percent\":null,\"wifi_rssi\":%ld,\"uptime_seconds\":%lu,\"wake_count\":%lu,%s,\"health\":\"%s\",\"last_error\":\"%s\",\"publish_reason\":\"%s\"}",
        timestamp,
        config->zone_id,
        publish_node_id,
        config->node_id,
        soil_fields,
        environment_fields,
        (long)wifi_rssi,
        (unsigned long)uptime_seconds,
        (unsigned long)wake_count,
        ip_field,
        snapshot->healthy ? "ok" : "degraded",
        last_error ? last_error : "none",
        reason
    );

    return written >= 0 && (size_t)written < out_size;
}
