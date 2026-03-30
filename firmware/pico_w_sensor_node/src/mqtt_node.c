#include "mqtt_node.h"

#include <stdio.h>
#include <string.h>

#include "lwip/apps/mqtt.h"
#include "lwip/ip_addr.h"
#include "lwip/ip4_addr.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "topics.h"
#include "wifi.h"

#define MQTT_RX_TOPIC_MAX 128
#define MQTT_RX_PAYLOAD_MAX 1024
#define MQTT_TX_PAYLOAD_MAX 1024

typedef struct {
    mqtt_node_t *node;
    mqtt_client_t *client;
    bool connected;
    absolute_time_t next_reconnect_at;
    char incoming_topic[MQTT_RX_TOPIC_MAX];
    char incoming_payload[MQTT_RX_PAYLOAD_MAX];
    size_t incoming_payload_len;
} mqtt_runtime_t;

static mqtt_runtime_t g_runtime;

static const struct mqtt_connect_client_info_t g_client_info_template = {
    .client_id = NULL,
    .client_user = NULL,
    .client_pass = NULL,
    .keep_alive = 60,
    .will_topic = NULL,
    .will_msg = NULL,
    .will_msg_len = 0,
    .will_qos = 0,
    .will_retain = 0,
};

static void iso_timestamp_now(char *out, size_t out_size) {
    uint32_t seconds = to_ms_since_boot(get_absolute_time()) / 1000u;
    snprintf(out, out_size, "1970-01-01T00:%02u:%02uZ", (seconds / 60u) % 60u, seconds % 60u);
}

static void set_error(mqtt_node_t *node, const char *message) {
    snprintf(node->last_error, sizeof(node->last_error), "%s", message ? message : "none");
}

static void set_errorf(mqtt_node_t *node, const char *prefix, err_t err) {
    snprintf(node->last_error, sizeof(node->last_error), "%s err=%d", prefix, err);
}

static err_t mqtt_publish_locked(mqtt_client_t *client, const char *topic, const void *payload,
                                 u16_t payload_length, u8_t qos, u8_t retain,
                                 mqtt_request_cb_t cb, void *arg) {
    cyw43_arch_lwip_begin();
    err_t err = mqtt_publish(client, topic, payload, payload_length, qos, retain, cb, arg);
    cyw43_arch_lwip_end();
    return err;
}

static err_t mqtt_subscribe_locked(mqtt_client_t *client, const char *topic, u8_t qos,
                                   mqtt_request_cb_t cb, void *arg) {
    cyw43_arch_lwip_begin();
    err_t err = mqtt_subscribe(client, topic, qos, cb, arg);
    cyw43_arch_lwip_end();
    return err;
}

static err_t mqtt_client_connect_locked(mqtt_client_t *client, const ip_addr_t *ipaddr, u16_t port,
                                        mqtt_connection_cb_t cb, void *arg,
                                        const struct mqtt_connect_client_info_t *client_info) {
    cyw43_arch_lwip_begin();
    err_t err = mqtt_client_connect(client, ipaddr, port, cb, arg, client_info);
    cyw43_arch_lwip_end();
    return err;
}

static bool extract_json_string(const char *payload, const char *key, char *out, size_t out_size) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char *start = strstr(payload, pattern);
    if (!start) {
        return false;
    }
    start += strlen(pattern);
    const char *end = strchr(start, '"');
    if (!end) {
        return false;
    }
    size_t len = (size_t)(end - start);
    if (len >= out_size) {
        len = out_size - 1;
    }
    memcpy(out, start, len);
    out[len] = '\0';
    return true;
}

static bool topic_equals(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

static void clear_retained_command(mqtt_node_t *node) {
    char topic[MQTT_RX_TOPIC_MAX];
    topic_command(node->config, topic, sizeof(topic));
    mqtt_publish_locked(g_runtime.client, topic, "", 0, 0, 1, NULL, NULL);
}

static void publish_command_ack(mqtt_node_t *node, const char *command, const char *command_id, const char *status) {
    char topic[MQTT_RX_TOPIC_MAX];
    char payload[MQTT_TX_PAYLOAD_MAX];
    topic_command_ack(node->config, topic, sizeof(topic));

    snprintf(
        payload,
        sizeof(payload),
        "{\"schema_version\":\"node-command-ack/v1\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"command\":\"%s\",\"command_id\":\"%s\",\"status\":\"%s\"}",
        node->config->zone_id,
        node->config->node_id,
        command,
        command_id,
        status
    );
    mqtt_publish_locked(g_runtime.client, topic, payload, (u16_t)strlen(payload), 0, 1, NULL, NULL);
}

static void publish_config_ack(mqtt_node_t *node, const char *status, const char *error_message) {
    char topic[MQTT_RX_TOPIC_MAX];
    char payload[MQTT_TX_PAYLOAD_MAX];
    char timestamp[32];
    topic_node_config_ack(node->config, topic, sizeof(topic));
    iso_timestamp_now(timestamp, sizeof(timestamp));

    if (node->config->assigned) {
        snprintf(
            payload,
            sizeof(payload),
            "{\"schema_version\":\"node-config-ack/v1\",\"node_id\":\"%s\",\"config_version\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"applied_config\":{\"assigned\":true,\"zone_id\":\"%s\",\"crop_id\":\"%s\"},\"error\":%s}",
            node->config->node_id,
            node->config->config_version,
            status,
            timestamp,
            node->config->zone_id,
            node->config->zone_id,
            node->config->crop_id,
            error_message ? error_message : "null"
        );
    } else {
        snprintf(
            payload,
            sizeof(payload),
            "{\"schema_version\":\"node-config-ack/v1\",\"node_id\":\"%s\",\"config_version\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"applied_config\":{\"assigned\":false},\"error\":%s}",
            node->config->node_id,
            node->config->config_version,
            status,
            timestamp,
            node->config->zone_id,
            error_message ? error_message : "null"
        );
    }

    mqtt_publish_locked(g_runtime.client, topic, payload, (u16_t)strlen(payload), 0, 1, NULL, NULL);
}

static void mqtt_request_cb(void *arg, err_t err) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    if (err != ERR_OK) {
        set_error(node, "mqtt request failed");
    }
}

static void handle_command_message(mqtt_node_t *node, const char *payload) {
    char command[32] = {0};
    char command_id[64] = {0};

    if (!extract_json_string(payload, "command", command, sizeof(command)) ||
        !extract_json_string(payload, "command_id", command_id, sizeof(command_id))) {
        set_error(node, "invalid command payload");
        return;
    }

    if (strcmp(command, "request_reading") == 0) {
        publish_command_ack(node, command, command_id, "acknowledged");
        clear_retained_command(node);
        node->publish_requested = true;
        set_error(node, "none");
    } else {
        publish_command_ack(node, command, command_id, "ignored");
    }
}

static void handle_config_message(mqtt_node_t *node, const char *payload) {
    bool zone_changed = false;
    char error[128];

    if (node_config_apply_json(node->config, payload, &zone_changed, error, sizeof(error))) {
        if (!node_config_save(node->config, error, sizeof(error))) {
            set_error(node, error);
            publish_config_ack(node, "error", "\"flash save failed\"");
            return;
        }
        publish_config_ack(node, "applied", NULL);
        node->publish_requested = true;
        node->config_changed_requires_reconnect = zone_changed;
        set_error(node, "none");
    } else {
        set_error(node, error);
        publish_config_ack(node, "error", "\"config apply failed\"");
    }
}

static void handle_incoming_message(mqtt_node_t *node) {
    char command_topic[MQTT_RX_TOPIC_MAX];
    char config_topic[MQTT_RX_TOPIC_MAX];
    topic_command(node->config, command_topic, sizeof(command_topic));
    topic_node_config(node->config, config_topic, sizeof(config_topic));

    if (topic_equals(g_runtime.incoming_topic, command_topic)) {
        handle_command_message(node, g_runtime.incoming_payload);
    } else if (topic_equals(g_runtime.incoming_topic, config_topic)) {
        handle_config_message(node, g_runtime.incoming_payload);
    }
}

static void mqtt_incoming_publish_cb(void *arg, const char *topic, u32_t tot_len) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    (void)node;
    snprintf(g_runtime.incoming_topic, sizeof(g_runtime.incoming_topic), "%s", topic);
    g_runtime.incoming_payload_len = 0;
    if (tot_len >= MQTT_RX_PAYLOAD_MAX) {
        g_runtime.incoming_topic[0] = '\0';
    }
}

static void mqtt_incoming_data_cb(void *arg, const u8_t *data, u16_t len, u8_t flags) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    if (g_runtime.incoming_topic[0] == '\0' || !data) {
        return;
    }
    if (g_runtime.incoming_payload_len + len >= sizeof(g_runtime.incoming_payload)) {
        set_error(node, "incoming payload too large");
        g_runtime.incoming_topic[0] = '\0';
        g_runtime.incoming_payload_len = 0;
        return;
    }
    memcpy(g_runtime.incoming_payload + g_runtime.incoming_payload_len, data, len);
    g_runtime.incoming_payload_len += len;
    g_runtime.incoming_payload[g_runtime.incoming_payload_len] = '\0';

    if (flags & MQTT_DATA_FLAG_LAST) {
        handle_incoming_message(node);
        g_runtime.incoming_topic[0] = '\0';
        g_runtime.incoming_payload_len = 0;
    }
}

static void subscribe_topics(mqtt_node_t *node) {
    char command_topic[MQTT_RX_TOPIC_MAX];
    char config_topic[MQTT_RX_TOPIC_MAX];
    topic_command(node->config, command_topic, sizeof(command_topic));
    topic_node_config(node->config, config_topic, sizeof(config_topic));
    mqtt_subscribe_locked(g_runtime.client, command_topic, 0, mqtt_request_cb, node);
    mqtt_subscribe_locked(g_runtime.client, config_topic, 0, mqtt_request_cb, node);
}

static void mqtt_connection_cb(mqtt_client_t *client, void *arg, mqtt_connection_status_t status) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    (void)client;
    printf("[mqtt_cb] status=%d\n", (int)status);
    g_runtime.connected = (status == MQTT_CONNECT_ACCEPTED);
    if (g_runtime.connected) {
        g_runtime.next_reconnect_at = get_absolute_time();
        mqtt_set_inpub_callback(g_runtime.client, mqtt_incoming_publish_cb, mqtt_incoming_data_cb, node);
        subscribe_topics(node);
        node->publish_requested = true;
        set_error(node, "none");
    } else {
        printf("[mqtt_cb] not accepted — status=%d\n", (int)status);
        set_error(node, "mqtt disconnected");
        g_runtime.next_reconnect_at = make_timeout_time_ms(5000);
    }
}

static bool parse_broker_ip(const node_config_t *config, ip_addr_t *addr) {
    return ipaddr_aton(config->mqtt_host, addr) != 0;
}

void mqtt_node_init(mqtt_node_t *node, node_config_t *config) {
    memset(node, 0, sizeof(*node));
    node->config = config;
    snprintf(node->last_error, sizeof(node->last_error), "none");
    memset(&g_runtime, 0, sizeof(g_runtime));
    g_runtime.node = node;
    g_runtime.next_reconnect_at = get_absolute_time();
}

static void mqtt_ensure_connected(mqtt_node_t *node) {
    if (g_runtime.connected || absolute_time_diff_us(get_absolute_time(), g_runtime.next_reconnect_at) > 0) {
        return;
    }
    if (!wifi_is_connected()) {
        g_runtime.next_reconnect_at = make_timeout_time_ms(5000);
        return;
    }

    if (!g_runtime.client) {
        g_runtime.client = mqtt_client_new();
    }
    if (!g_runtime.client) {
        set_error(node, "mqtt client alloc failed");
        g_runtime.next_reconnect_at = make_timeout_time_ms(5000);
        return;
    }

    ip_addr_t broker_addr;
    if (!parse_broker_ip(node->config, &broker_addr)) {
        set_error(node, "mqtt host must be an IP address");
        g_runtime.next_reconnect_at = make_timeout_time_ms(10000);
        return;
    }

    struct mqtt_connect_client_info_t info = g_client_info_template;
    info.client_id = node->config->node_id;
    printf("[mqtt] connecting to %s:%d\n", node->config->mqtt_host, node->config->mqtt_port);
    err_t err = mqtt_client_connect_locked(
        g_runtime.client,
        &broker_addr,
        node->config->mqtt_port,
        mqtt_connection_cb,
        node,
        &info
    );
    if (err != ERR_OK) {
        char message[64];
        snprintf(message, sizeof(message), "mqtt connect failed err=%d", err);
        printf("[mqtt] %s\n", message);
        set_error(node, message);
        g_runtime.next_reconnect_at = make_timeout_time_ms(5000);
    } else {
        printf("[mqtt] connect initiated — waiting for callback\n");
        g_runtime.next_reconnect_at = make_timeout_time_ms(15000);
    }
}

void mqtt_node_poll(mqtt_node_t *node) {
    (void)node;
    mqtt_ensure_connected(g_runtime.node);
}

bool mqtt_node_is_connected(const mqtt_node_t *node) {
    (void)node;
    return g_runtime.connected && g_runtime.client && mqtt_client_is_connected(g_runtime.client);
}

bool mqtt_node_publish_canary(mqtt_node_t *node) {
    if (!mqtt_node_is_connected(node)) {
        set_error(node, "mqtt not connected");
        return false;
    }

    err_t err = mqtt_publish_locked(g_runtime.client, "greenhouse/canary", "ok", 2, 0, 0, NULL, NULL);
    if (err == ERR_OK) {
        set_error(node, "none");
        return true;
    }

    if (err == ERR_MEM) {
        set_error(node, "mqtt canary buffer full");
    } else {
        set_errorf(node, "mqtt canary failed", err);
    }
    return false;
}

bool mqtt_node_publish_state(mqtt_node_t *node, const sensor_snapshot_t *snapshot, const char *reason) {
    if (!mqtt_node_is_connected(node)) {
        set_error(node, "mqtt not connected");
        return false;
    }

    char topic[MQTT_RX_TOPIC_MAX];
    char timestamp[32];
    char ip[32];
    char payload[MQTT_TX_PAYLOAD_MAX];
    int32_t rssi = wifi_rssi();
    bool has_ip = wifi_ip_string(ip, sizeof(ip));
    topic_state(node->config, topic, sizeof(topic));
    iso_timestamp_now(timestamp, sizeof(timestamp));

    if (has_ip) {
        snprintf(
            payload,
            sizeof(payload),
            "{\"schema_version\":\"node-state/v1\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"moisture_raw\":%u,\"moisture_percent\":%d,\"soil_temp_c\":null,\"battery_voltage\":null,\"battery_percent\":null,\"wifi_rssi\":%ld,\"uptime_seconds\":%lu,\"wake_count\":%lu,\"ip\":\"%s\",\"health\":\"%s\",\"last_error\":\"%s\",\"publish_reason\":\"%s\"}",
            timestamp,
            node->config->zone_id,
            node->config->node_id,
            snapshot->moisture_raw,
            snapshot->moisture_percent,
            (long)rssi,
            (unsigned long)(to_ms_since_boot(get_absolute_time()) / 1000u),
            (unsigned long)(to_ms_since_boot(get_absolute_time()) / 1000u),
            ip,
            snapshot->healthy ? "ok" : "degraded",
            node->last_error,
            reason
        );
    } else {
        snprintf(
            payload,
            sizeof(payload),
            "{\"schema_version\":\"node-state/v1\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"moisture_raw\":%u,\"moisture_percent\":%d,\"soil_temp_c\":null,\"battery_voltage\":null,\"battery_percent\":null,\"wifi_rssi\":%ld,\"uptime_seconds\":%lu,\"wake_count\":%lu,\"ip\":null,\"health\":\"%s\",\"last_error\":\"%s\",\"publish_reason\":\"%s\"}",
            timestamp,
            node->config->zone_id,
            node->config->node_id,
            snapshot->moisture_raw,
            snapshot->moisture_percent,
            (long)rssi,
            (unsigned long)(to_ms_since_boot(get_absolute_time()) / 1000u),
            (unsigned long)(to_ms_since_boot(get_absolute_time()) / 1000u),
            snapshot->healthy ? "ok" : "degraded",
            node->last_error,
            reason
        );
    }

    err_t err = mqtt_publish_locked(g_runtime.client, topic, payload, (u16_t)strlen(payload), 0, 1, mqtt_request_cb, node);
    if (err == ERR_OK) {
        set_error(node, "none");
        return true;
    }

    if (err == ERR_MEM) {
        set_error(node, "mqtt publish buffer full");
    } else {
        set_errorf(node, "mqtt publish failed", err);
    }

    return false;
}

bool mqtt_node_take_publish_request(mqtt_node_t *node) {
    bool requested = node->publish_requested;
    node->publish_requested = false;
    return requested;
}

bool mqtt_node_take_reconnect_request(mqtt_node_t *node) {
    bool requested = node->config_changed_requires_reconnect;
    if (requested) {
        node->config_changed_requires_reconnect = false;
        if (g_runtime.client) {
            cyw43_arch_lwip_begin();
            mqtt_disconnect(g_runtime.client);
            cyw43_arch_lwip_end();
            mqtt_client_free(g_runtime.client);
            g_runtime.client = NULL;
        }
        g_runtime.connected = false;
        g_runtime.next_reconnect_at = get_absolute_time();
    }
    return requested;
}
