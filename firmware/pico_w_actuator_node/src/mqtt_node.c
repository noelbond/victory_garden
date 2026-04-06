#include "mqtt_node.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "hardware/gpio.h"
#include "lwip/ip.h"
#include "lwip/apps/mqtt.h"
#include "lwip/ip4_addr.h"
#include "lwip/ip_addr.h"
#include "lwip/pbuf.h"
#include "lwip/udp.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "time_sync.h"
#include "topics.h"
#include "wifi.h"

#define MQTT_RX_TOPIC_MAX 128
#define MQTT_RX_PAYLOAD_MAX 1024
#define MQTT_TX_PAYLOAD_MAX 1024
#define MQTT_DISCOVERY_PORT 44737u
#define MQTT_DISCOVERY_INTERVAL_MS 10000u
#define MQTT_DISCOVERY_TIMEOUT_MS 2000u
#define MQTT_DISCOVERY_REQUEST_PAYLOAD "{\"schema_version\":\"mqtt-discovery/v1\",\"command\":\"discover\"}"

typedef struct {
    mqtt_node_t *node;
    mqtt_client_t *client;
    struct udp_pcb *discovery_pcb;
    bool connected;
    bool discovery_in_progress;
    bool discovery_resolved;
    absolute_time_t next_reconnect_at;
    absolute_time_t discovery_next_attempt_at;
    absolute_time_t discovery_deadline;
    char incoming_topic[MQTT_RX_TOPIC_MAX];
    char incoming_payload[MQTT_RX_PAYLOAD_MAX];
    char discovered_mqtt_host[VG_MAX_HOST_LEN];
    size_t incoming_payload_len;
    uint16_t discovered_mqtt_port;
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

static void mqtt_request_cb(void *arg, err_t err);

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

static bool decode_json_string(const char *start, char *out, size_t out_size, const char **end_out) {
    size_t out_len = 0;
    const char *cursor = start;

    if (!start || !out || out_size == 0) {
        return false;
    }

    while (*cursor != '\0') {
        char ch = *cursor++;
        if (ch == '"') {
            out[out_len] = '\0';
            if (end_out) {
                *end_out = cursor;
            }
            return true;
        }

        if (ch == '\\') {
            ch = *cursor++;
            switch (ch) {
                case '"':
                case '\\':
                case '/':
                    break;
                case 'b':
                    ch = '\b';
                    break;
                case 'f':
                    ch = '\f';
                    break;
                case 'n':
                    ch = '\n';
                    break;
                case 'r':
                    ch = '\r';
                    break;
                case 't':
                    ch = '\t';
                    break;
                default:
                    return false;
            }
        }

        if (out_len + 1 < out_size) {
            out[out_len++] = ch;
        }
    }

    return false;
}

static bool extract_json_string(const char *payload, const char *key, char *out, size_t out_size) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char *start = strstr(payload, pattern);
    if (!start) {
        return false;
    }
    start += strlen(pattern);
    return decode_json_string(start, out, out_size, NULL);
}

static bool extract_json_int(const char *payload, const char *key, int *out) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *start = strstr(payload, pattern);
    if (!start) {
        return false;
    }
    start += strlen(pattern);
    *out = (int)strtol(start, NULL, 10);
    return true;
}

static void mqtt_close_broker_discovery(void) {
    if (!g_runtime.discovery_pcb) {
        g_runtime.discovery_in_progress = false;
        return;
    }

    cyw43_arch_lwip_begin();
    udp_remove(g_runtime.discovery_pcb);
    cyw43_arch_lwip_end();
    g_runtime.discovery_pcb = NULL;
    g_runtime.discovery_in_progress = false;
}

static void mqtt_discovery_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p, const ip_addr_t *addr, u16_t port) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    (void)pcb;
    (void)addr;
    (void)port;

    if (!p) {
        return;
    }

    char payload[256];
    const u16_t copy_len = p->tot_len < sizeof(payload) - 1 ? p->tot_len : (sizeof(payload) - 1);
    pbuf_copy_partial(p, payload, copy_len, 0);
    payload[copy_len] = '\0';
    pbuf_free(p);

    char schema[32] = {0};
    char host[VG_MAX_HOST_LEN] = {0};
    int mqtt_port = 0;
    if (!extract_json_string(payload, "schema_version", schema, sizeof(schema)) ||
        strcmp(schema, "mqtt-discovery/v1") != 0 ||
        !extract_json_string(payload, "mqtt_host", host, sizeof(host)) ||
        !extract_json_int(payload, "mqtt_port", &mqtt_port) ||
        mqtt_port <= 0 || mqtt_port > 65535) {
        if (node) {
            set_error(node, "broker discovery invalid response");
        }
        return;
    }

    snprintf(g_runtime.discovered_mqtt_host, sizeof(g_runtime.discovered_mqtt_host), "%s", host);
    g_runtime.discovered_mqtt_port = (uint16_t)mqtt_port;
    g_runtime.discovery_resolved = true;
}

static void mqtt_start_broker_discovery(mqtt_node_t *node) {
    if (g_runtime.discovery_in_progress ||
        absolute_time_diff_us(get_absolute_time(), g_runtime.discovery_next_attempt_at) > 0 ||
        !wifi_is_connected()) {
        return;
    }

    struct udp_pcb *pcb = NULL;
    struct pbuf *packet = NULL;
    err_t err = ERR_OK;

    cyw43_arch_lwip_begin();
    pcb = udp_new_ip_type(IPADDR_TYPE_ANY);
    if (pcb) {
        ip_set_option(pcb, SOF_BROADCAST);
        err = udp_bind(pcb, IP_ANY_TYPE, 0);
        if (err == ERR_OK) {
            udp_recv(pcb, mqtt_discovery_recv, node);
            packet = pbuf_alloc(PBUF_TRANSPORT, sizeof(MQTT_DISCOVERY_REQUEST_PAYLOAD) - 1u, PBUF_RAM);
            if (packet) {
                memcpy(packet->payload, MQTT_DISCOVERY_REQUEST_PAYLOAD, sizeof(MQTT_DISCOVERY_REQUEST_PAYLOAD) - 1u);
                err = udp_sendto(pcb, packet, IP_ADDR_BROADCAST, MQTT_DISCOVERY_PORT);
            } else {
                err = ERR_MEM;
            }
        }
    } else {
        err = ERR_MEM;
    }
    if (packet) {
        pbuf_free(packet);
    }
    cyw43_arch_lwip_end();

    if (err != ERR_OK || !pcb) {
        if (pcb) {
            cyw43_arch_lwip_begin();
            udp_remove(pcb);
            cyw43_arch_lwip_end();
        }
        set_error(node, "broker discovery start failed");
        g_runtime.discovery_in_progress = false;
        g_runtime.discovery_next_attempt_at = make_timeout_time_ms(MQTT_DISCOVERY_INTERVAL_MS);
        return;
    }

    g_runtime.discovery_pcb = pcb;
    g_runtime.discovery_in_progress = true;
    g_runtime.discovery_resolved = false;
    g_runtime.discovery_deadline = make_timeout_time_ms(MQTT_DISCOVERY_TIMEOUT_MS);
    g_runtime.discovery_next_attempt_at = make_timeout_time_ms(MQTT_DISCOVERY_INTERVAL_MS);
    printf("[mqtt] broker discovery broadcast sent\n");
}

static void mqtt_apply_discovered_broker(mqtt_node_t *node) {
    if (!g_runtime.discovery_resolved) {
        return;
    }

    g_runtime.discovery_resolved = false;
    mqtt_close_broker_discovery();

    const bool changed = strcmp(node->config->mqtt_host, g_runtime.discovered_mqtt_host) != 0 ||
                         node->config->mqtt_port != g_runtime.discovered_mqtt_port;
    snprintf(node->config->mqtt_host, sizeof(node->config->mqtt_host), "%s", g_runtime.discovered_mqtt_host);
    node->config->mqtt_port = g_runtime.discovered_mqtt_port;
    printf("[mqtt] broker discovered host=%s port=%u changed=%d\n",
           node->config->mqtt_host,
           (unsigned)node->config->mqtt_port,
           (int)changed);

    if (changed) {
        char error[64];
        if (!node_config_save(node->config, error, sizeof(error))) {
            printf("[mqtt] broker save failed: %s\n", error);
        }
    }

    g_runtime.next_reconnect_at = get_absolute_time();
    set_error(node, "none");
}

static void mqtt_poll_broker_discovery(mqtt_node_t *node) {
    if (g_runtime.connected && g_runtime.client && mqtt_client_is_connected(g_runtime.client)) {
        if (g_runtime.discovery_in_progress || g_runtime.discovery_pcb) {
            mqtt_close_broker_discovery();
        }
        return;
    }

    if (g_runtime.discovery_resolved) {
        mqtt_apply_discovered_broker(node);
        return;
    }

    if (g_runtime.discovery_in_progress &&
        absolute_time_diff_us(get_absolute_time(), g_runtime.discovery_deadline) <= 0) {
        printf("[mqtt] broker discovery timed out\n");
        mqtt_close_broker_discovery();
    }

    if (!g_runtime.discovery_in_progress) {
        mqtt_start_broker_discovery(node);
    }
}

static bool topic_equals(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

static const char *actuator_status_name(actuator_status_t status) {
    switch (status) {
        case ACTUATOR_STATUS_ACKNOWLEDGED:
            return "ACKNOWLEDGED";
        case ACTUATOR_STATUS_RUNNING:
            return "RUNNING";
        case ACTUATOR_STATUS_COMPLETED:
            return "COMPLETED";
        case ACTUATOR_STATUS_STOPPED:
            return "STOPPED";
        case ACTUATOR_STATUS_FAULT:
            return "FAULT";
        case ACTUATOR_STATUS_NONE:
        default:
            return "UNKNOWN";
    }
}

static void config_ack_timestamp(const mqtt_node_t *node, char *out, size_t out_size) {
    if (!out || out_size == 0) {
        return;
    }

    if (time_sync_ready()) {
        time_sync_format_iso8601(out, out_size);
        return;
    }

    if (node->config->config_version[0] != '\0') {
        snprintf(out, out_size, "%s", node->config->config_version);
        return;
    }

    time_sync_format_iso8601(out, out_size);
}

static void actuator_set_output(mqtt_node_t *node, bool enabled) {
    bool level = enabled ? node->config->actuator_relay_active_high : !node->config->actuator_relay_active_high;
    gpio_put(node->config->actuator_relay_gpio, level ? 1u : 0u);
    node->actuator_relay_enabled = enabled;
    printf("[actuator] relay gp=%u enabled=%d level=%d\n",
           (unsigned)node->config->actuator_relay_gpio,
           (int)enabled,
           (int)level);
}

static void actuator_queue_status(mqtt_node_t *node, actuator_status_t status,
                                  const char *fault_code, const char *fault_detail) {
    node->pending_actuator_status = status;
    node->actuator_status_pending = true;
    snprintf(node->actuator_fault_code, sizeof(node->actuator_fault_code), "%s", fault_code ? fault_code : "");
    snprintf(node->actuator_fault_detail, sizeof(node->actuator_fault_detail), "%s", fault_detail ? fault_detail : "");
}

static uint32_t actuator_elapsed_seconds(const mqtt_node_t *node) {
    uint32_t now_ms = to_ms_since_boot(get_absolute_time());
    if (now_ms <= node->actuator_started_at_ms) {
        return 0u;
    }
    return (now_ms - node->actuator_started_at_ms) / 1000u;
}

static bool mqtt_publish_actuator_status_now(mqtt_node_t *node, actuator_status_t status,
                                             const char *fault_code, const char *fault_detail) {
    if (!g_runtime.connected || !g_runtime.client || !mqtt_client_is_connected(g_runtime.client)) {
        actuator_queue_status(node, status, fault_code, fault_detail);
        return false;
    }

    char topic[MQTT_RX_TOPIC_MAX];
    char timestamp[32];
    char payload[MQTT_TX_PAYLOAD_MAX];
    char actual_runtime_json[24];
    char fault_code_json[64];
    char fault_detail_json[160];
    topic_actuator_status(node->config, topic, sizeof(topic));
    time_sync_format_iso8601(timestamp, sizeof(timestamp));

    if (status == ACTUATOR_STATUS_ACKNOWLEDGED) {
        snprintf(actual_runtime_json, sizeof(actual_runtime_json), "null");
    } else {
        snprintf(actual_runtime_json, sizeof(actual_runtime_json), "%lu",
                 (unsigned long)actuator_elapsed_seconds(node));
    }

    if (fault_code && fault_code[0] != '\0') {
        snprintf(fault_code_json, sizeof(fault_code_json), "\"%s\"", fault_code);
    } else {
        snprintf(fault_code_json, sizeof(fault_code_json), "null");
    }

    if (fault_detail && fault_detail[0] != '\0') {
        snprintf(fault_detail_json, sizeof(fault_detail_json), "\"%s\"", fault_detail);
    } else {
        snprintf(fault_detail_json, sizeof(fault_detail_json), "null");
    }

    snprintf(
        payload,
        sizeof(payload),
        "{\"zone_id\":\"%s\",\"state\":\"%s\",\"timestamp\":\"%s\",\"idempotency_key\":\"%s\",\"actual_runtime_seconds\":%s,\"flow_ml\":null,\"fault_code\":%s,\"fault_detail\":%s}",
        node->config->zone_id,
        actuator_status_name(status),
        timestamp,
        node->actuator_idempotency_key,
        actual_runtime_json,
        fault_code_json,
        fault_detail_json
    );

    err_t err = mqtt_publish_locked(g_runtime.client, topic, payload, (u16_t)strlen(payload), 0, 1, mqtt_request_cb, node);
    if (err == ERR_OK) {
        node->actuator_status_pending = false;
        node->pending_actuator_status = ACTUATOR_STATUS_NONE;
        node->actuator_fault_code[0] = '\0';
        node->actuator_fault_detail[0] = '\0';
        set_error(node, "none");
        return true;
    }

    actuator_queue_status(node, status, fault_code, fault_detail);
    if (err == ERR_MEM) {
        set_error(node, "mqtt actuator status buffer full");
    } else {
        set_errorf(node, "mqtt actuator status failed", err);
    }
    return false;
}

static void actuator_stop_with_status(mqtt_node_t *node, actuator_status_t status,
                                      const char *fault_code, const char *fault_detail) {
    printf("[actuator] stop status=%s fault=%s\n",
           actuator_status_name(status),
           fault_code ? fault_code : "none");
    actuator_set_output(node, false);
    node->actuator_running = false;
    mqtt_publish_actuator_status_now(node, status, fault_code, fault_detail);
}

static void clear_retained_topic(const char *topic) {
    mqtt_publish_locked(g_runtime.client, topic, "", 0, 0, 1, NULL, NULL);
}

static void clear_retained_actuator_command(mqtt_node_t *node) {
    char topic[MQTT_RX_TOPIC_MAX];
    topic_actuator_command(node->config, topic, sizeof(topic));
    clear_retained_topic(topic);
}

static void publish_config_ack(mqtt_node_t *node, const char *status, const char *error_message) {
    char topic[MQTT_RX_TOPIC_MAX];
    char payload[MQTT_TX_PAYLOAD_MAX];
    char timestamp[32];
    topic_node_config_ack(node->config, topic, sizeof(topic));
    config_ack_timestamp(node, timestamp, sizeof(timestamp));

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

static void handle_actuator_command_message(mqtt_node_t *node, const char *payload) {
    char command[32] = {0};
    char idempotency_key[96] = {0};
    int runtime_seconds = 0;

    if (!extract_json_string(payload, "command", command, sizeof(command)) ||
        !extract_json_string(payload, "idempotency_key", idempotency_key, sizeof(idempotency_key))) {
        set_error(node, "invalid actuator payload");
        return;
    }

    clear_retained_actuator_command(node);

    if (strcmp(command, "stop_watering") == 0) {
        printf("[actuator] command=stop id=%s\n", idempotency_key);
        snprintf(node->actuator_idempotency_key, sizeof(node->actuator_idempotency_key), "%s", idempotency_key);
        actuator_stop_with_status(node, ACTUATOR_STATUS_STOPPED, NULL, NULL);
        set_error(node, "none");
        return;
    }

    if (strcmp(command, "start_watering") != 0) {
        set_error(node, "unsupported actuator command");
        return;
    }

    if (!extract_json_int(payload, "runtime_seconds", &runtime_seconds) || runtime_seconds <= 0) {
        set_error(node, "invalid actuator runtime");
        return;
    }

    printf("[actuator] command=%s id=%s runtime=%d running=%d\n",
           command,
           idempotency_key,
           runtime_seconds,
           (int)node->actuator_running);

    if ((uint16_t)runtime_seconds > node->config->max_pulse_runtime_sec && node->config->max_pulse_runtime_sec > 0) {
        runtime_seconds = (int)node->config->max_pulse_runtime_sec;
    }

    snprintf(node->actuator_idempotency_key, sizeof(node->actuator_idempotency_key), "%s", idempotency_key);
    node->actuator_started_at_ms = to_ms_since_boot(get_absolute_time());
    node->actuator_runtime_seconds = (uint32_t)runtime_seconds;
    node->actuator_hard_deadline = make_timeout_time_ms((uint32_t)runtime_seconds * 1000u);
    mqtt_publish_actuator_status_now(node, ACTUATOR_STATUS_ACKNOWLEDGED, NULL, NULL);
    actuator_set_output(node, true);
    node->actuator_running = true;
    mqtt_publish_actuator_status_now(node, ACTUATOR_STATUS_RUNNING, NULL, NULL);

    set_error(node, "none");
}

static void handle_config_message(mqtt_node_t *node, const char *payload) {
    bool zone_changed = false;
    char error[128];
    char config_version[VG_MAX_CONFIG_VERSION_LEN] = {0};

    if (extract_json_string(payload, "config_version", config_version, sizeof(config_version)) &&
        config_version[0] != '\0' &&
        strcmp(config_version, node->config->config_version) == 0) {
        publish_config_ack(node, "applied", NULL);
        set_error(node, "none");
        return;
    }

    if (node_config_apply_json(node->config, payload, &zone_changed, error, sizeof(error))) {
        if (!node_config_save(node->config, error, sizeof(error))) {
            set_error(node, error);
            publish_config_ack(node, "error", "\"flash save failed\"");
            return;
        }
        publish_config_ack(node, "applied", NULL);
        node->config_changed_requires_reconnect = zone_changed;
        set_error(node, "none");
    } else {
        set_error(node, error);
        publish_config_ack(node, "error", "\"config apply failed\"");
    }
}

static void handle_incoming_message(mqtt_node_t *node) {
    char actuator_command_topic[MQTT_RX_TOPIC_MAX];
    char config_topic[MQTT_RX_TOPIC_MAX];
    topic_actuator_command(node->config, actuator_command_topic, sizeof(actuator_command_topic));
    topic_node_config(node->config, config_topic, sizeof(config_topic));

    if (topic_equals(g_runtime.incoming_topic, actuator_command_topic)) {
        handle_actuator_command_message(node, g_runtime.incoming_payload);
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
    char actuator_command_topic[MQTT_RX_TOPIC_MAX];
    char config_topic[MQTT_RX_TOPIC_MAX];
    topic_actuator_command(node->config, actuator_command_topic, sizeof(actuator_command_topic));
    topic_node_config(node->config, config_topic, sizeof(config_topic));
    mqtt_subscribe_locked(g_runtime.client, actuator_command_topic, 0, mqtt_request_cb, node);
    mqtt_subscribe_locked(g_runtime.client, config_topic, 0, mqtt_request_cb, node);
}

static void mqtt_connection_cb(mqtt_client_t *client, void *arg, mqtt_connection_status_t status) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    (void)client;
    printf("[mqtt_cb] status=%d\n", (int)status);
    g_runtime.connected = (status == MQTT_CONNECT_ACCEPTED);
    if (g_runtime.connected) {
        mqtt_close_broker_discovery();
        g_runtime.next_reconnect_at = get_absolute_time();
        mqtt_set_inpub_callback(g_runtime.client, mqtt_incoming_publish_cb, mqtt_incoming_data_cb, node);
        subscribe_topics(node);
        set_error(node, "none");
    } else {
        printf("[mqtt_cb] not accepted - status=%d\n", (int)status);
        set_error(node, "mqtt disconnected");
        g_runtime.next_reconnect_at = make_timeout_time_ms(5000);
        g_runtime.discovery_next_attempt_at = get_absolute_time();
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
    g_runtime.discovery_next_attempt_at = get_absolute_time();

    gpio_init(config->actuator_relay_gpio);
    gpio_set_dir(config->actuator_relay_gpio, GPIO_OUT);
    actuator_set_output(node, false);
    printf("[actuator] initialized gp=%u active_high=%d\n",
           (unsigned)config->actuator_relay_gpio,
           (int)config->actuator_relay_active_high);
}

static void mqtt_ensure_connected(mqtt_node_t *node) {
    if (g_runtime.connected || absolute_time_diff_us(get_absolute_time(), g_runtime.next_reconnect_at) > 0) {
        return;
    }
    if (!wifi_is_connected()) {
        g_runtime.next_reconnect_at = make_timeout_time_ms(5000);
        return;
    }

    mqtt_poll_broker_discovery(node);
    if (g_runtime.discovery_in_progress || g_runtime.discovery_resolved) {
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
        g_runtime.discovery_next_attempt_at = get_absolute_time();
        g_runtime.next_reconnect_at = make_timeout_time_ms(10000);
        return;
    }

    struct mqtt_connect_client_info_t info = g_client_info_template;
    info.client_id = node->config->node_id;
    info.client_user = node->config->mqtt_username[0] != '\0' ? node->config->mqtt_username : NULL;
    info.client_pass = node->config->mqtt_password[0] != '\0' ? node->config->mqtt_password : NULL;
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
        g_runtime.discovery_next_attempt_at = get_absolute_time();
        g_runtime.next_reconnect_at = make_timeout_time_ms(5000);
    } else {
        printf("[mqtt] connect initiated - waiting for callback\n");
        g_runtime.next_reconnect_at = make_timeout_time_ms(15000);
    }
}

void mqtt_node_poll(mqtt_node_t *node) {
    mqtt_ensure_connected(g_runtime.node);

    if (node->actuator_status_pending) {
        mqtt_publish_actuator_status_now(
            node,
            node->pending_actuator_status,
            node->actuator_fault_code,
            node->actuator_fault_detail
        );
    }

    if (!node->actuator_running) {
        return;
    }

    if (absolute_time_diff_us(get_absolute_time(), node->actuator_hard_deadline) <= 0) {
        actuator_stop_with_status(node, ACTUATOR_STATUS_COMPLETED, NULL, NULL);
    }
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

bool mqtt_node_take_reconnect_request(mqtt_node_t *node) {
    bool requested = node->config_changed_requires_reconnect;
    node->config_changed_requires_reconnect = false;
    return requested;
}
