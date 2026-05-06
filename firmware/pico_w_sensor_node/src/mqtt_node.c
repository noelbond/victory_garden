#include "mqtt_node.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "lwip/ip.h"
#include "lwip/apps/mqtt.h"
#include "lwip/ip4_addr.h"
#include "lwip/ip_addr.h"
#include "lwip/netif.h"
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
#define MQTT_DISCOVERY_MAX_TARGETS 260u
#define MQTT_DISCOVERY_REQUEST_PAYLOAD "{\"schema_version\":\"mqtt-discovery/v1\",\"command\":\"discover\"}"

typedef struct {
    mqtt_node_t *node;
    mqtt_client_t *client;
    struct udp_pcb *discovery_pcb;
    bool connected;
    bool subscriptions_pending;
    bool discovery_in_progress;
    bool discovery_resolved;
    absolute_time_t next_reconnect_at;
    absolute_time_t discovery_next_attempt_at;
    absolute_time_t discovery_deadline;
    char incoming_topic[MQTT_RX_TOPIC_MAX];
    char incoming_payload[MQTT_RX_PAYLOAD_MAX];
    char discovered_mqtt_host[VG_MAX_HOST_LEN];
    char client_id[VG_MAX_NODE_ID_LEN + 8];
    char pending_command[32];
    char pending_command_id[64];
    char pending_command_status[16];
    char pending_config_payload[MQTT_RX_PAYLOAD_MAX];
    char tx_topic[MQTT_RX_TOPIC_MAX];
    char tx_payload[MQTT_TX_PAYLOAD_MAX];
    char tx_timestamp[32];
    char tx_ip[32];
    size_t incoming_payload_len;
    uint16_t discovered_mqtt_port;
    bool pending_command_ack;
    bool pending_clear_retained_command;
    bool pending_publish_request;
    bool publish_request_needs_command_clear;
    bool pending_config_apply;
    bool pending_reboot;
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
static void mqtt_state_publish_cb(void *arg, err_t err);

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

static bool mqtt_add_discovery_target(ip_addr_t *targets, size_t *target_count, size_t max_targets, const ip_addr_t *target) {
    if (!target || ip_addr_isany(target) || *target_count >= max_targets) {
        return false;
    }

    for (size_t i = 0; i < *target_count; ++i) {
        if (ip_addr_cmp(&targets[i], target)) {
            return false;
        }
    }

    ip_addr_copy(targets[*target_count], *target);
    ++(*target_count);
    return true;
}

static bool mqtt_add_ipv4_discovery_target(ip_addr_t *targets, size_t *target_count, size_t max_targets, const ip4_addr_t *target) {
    if (!target || ip4_addr_isany_val(*target)) {
        return false;
    }

    ip_addr_t addr;
    ip_addr_copy_from_ip4(addr, *target);
    return mqtt_add_discovery_target(targets, target_count, max_targets, &addr);
}

static size_t mqtt_build_discovery_targets(ip_addr_t *targets, size_t max_targets) {
    size_t target_count = 0;
    mqtt_add_discovery_target(targets, &target_count, max_targets, IP_ADDR_BROADCAST);

    struct netif *netif = netif_default;
    if (!netif) {
        return target_count;
    }

    const ip4_addr_t *ip = netif_ip4_addr(netif);
    const ip4_addr_t *mask = netif_ip4_netmask(netif);
    const ip4_addr_t *gateway = netif_ip4_gw(netif);
    if (!ip || ip4_addr_isany_val(*ip)) {
        return target_count;
    }

    if (mask && !ip4_addr_isany_val(*mask)) {
        ip4_addr_t directed_broadcast;
        directed_broadcast.addr = ip->addr | ~mask->addr;
        mqtt_add_ipv4_discovery_target(targets, &target_count, max_targets, &directed_broadcast);
    }
    mqtt_add_ipv4_discovery_target(targets, &target_count, max_targets, gateway);

    // Some APs drop broadcast packets. Sweep the local /24 as a fallback so the Pi
    // can still be found after DHCP changes its address.
    const uint32_t local_24 = ip->addr & PP_HTONL(0xFFFFFF00UL);
    for (uint32_t host = 1; host <= 254 && target_count < max_targets; ++host) {
        ip4_addr_t candidate;
        candidate.addr = local_24 | PP_HTONL(host);
        if (candidate.addr == ip->addr) {
            continue;
        }
        mqtt_add_ipv4_discovery_target(targets, &target_count, max_targets, &candidate);
    }

    return target_count;
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
                ip_addr_t targets[MQTT_DISCOVERY_MAX_TARGETS];
                const size_t target_count = mqtt_build_discovery_targets(targets, MQTT_DISCOVERY_MAX_TARGETS);
                bool sent_any = false;
                err = ERR_VAL;
                for (size_t i = 0; i < target_count; ++i) {
                    err_t send_err = udp_sendto(pcb, packet, &targets[i], MQTT_DISCOVERY_PORT);
                    if (send_err == ERR_OK) {
                        sent_any = true;
                    } else {
                        err = send_err;
                    }
                }
                if (sent_any) {
                    err = ERR_OK;
                }
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

static bool clear_retained_topic(mqtt_node_t *node, const char *topic) {
    err_t err = mqtt_publish_locked(g_runtime.client, topic, "", 0, 0, 1, NULL, NULL);
    if (err == ERR_OK) {
        return true;
    }

    if (node) {
        if (err == ERR_MEM) {
            set_error(node, "mqtt clear buffer full");
        } else {
            set_errorf(node, "mqtt clear failed", err);
        }
    }
    return false;
}

static bool clear_retained_command(mqtt_node_t *node) {
    char topic[MQTT_RX_TOPIC_MAX];
    topic_command(node->config, topic, sizeof(topic));
    return clear_retained_topic(node, topic);
}

static bool publish_command_ack(mqtt_node_t *node, const char *command, const char *command_id, const char *status) {
    topic_command_ack(node->config, g_runtime.tx_topic, sizeof(g_runtime.tx_topic));

    snprintf(
        g_runtime.tx_payload,
        sizeof(g_runtime.tx_payload),
        "{\"schema_version\":\"node-command-ack/v1\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"command\":\"%s\",\"command_id\":\"%s\",\"status\":\"%s\"}",
        node->config->zone_id,
        node->config->node_id,
        command,
        command_id,
        status
    );
    err_t err = mqtt_publish_locked(
        g_runtime.client,
        g_runtime.tx_topic,
        g_runtime.tx_payload,
        (u16_t)strlen(g_runtime.tx_payload),
        0,
        1,
        NULL,
        NULL);
    if (err == ERR_OK) {
        return true;
    }

    if (err == ERR_MEM) {
        set_error(node, "mqtt ack buffer full");
    } else {
        set_errorf(node, "mqtt ack failed", err);
    }
    return false;
}

static void publish_config_ack(mqtt_node_t *node, const char *status, const char *error_message) {
    topic_node_config_ack(node->config, g_runtime.tx_topic, sizeof(g_runtime.tx_topic));
    config_ack_timestamp(node, g_runtime.tx_timestamp, sizeof(g_runtime.tx_timestamp));

    if (node->config->assigned) {
        snprintf(
            g_runtime.tx_payload,
            sizeof(g_runtime.tx_payload),
            "{\"schema_version\":\"node-config-ack/v1\",\"node_id\":\"%s\",\"config_version\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"applied_config\":{\"assigned\":true,\"zone_id\":\"%s\",\"crop_id\":\"%s\"},\"error\":%s}",
            node->config->node_id,
            node->config->config_version,
            status,
            g_runtime.tx_timestamp,
            node->config->zone_id,
            node->config->zone_id,
            node->config->crop_id,
            error_message ? error_message : "null"
        );
    } else {
        snprintf(
            g_runtime.tx_payload,
            sizeof(g_runtime.tx_payload),
            "{\"schema_version\":\"node-config-ack/v1\",\"node_id\":\"%s\",\"config_version\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"applied_config\":{\"assigned\":false},\"error\":%s}",
            node->config->node_id,
            node->config->config_version,
            status,
            g_runtime.tx_timestamp,
            node->config->zone_id,
            error_message ? error_message : "null"
        );
    }

    mqtt_publish_locked(
        g_runtime.client,
        g_runtime.tx_topic,
        g_runtime.tx_payload,
        (u16_t)strlen(g_runtime.tx_payload),
        0,
        1,
        NULL,
        NULL);
}

static void mqtt_request_cb(void *arg, err_t err) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    if (err != ERR_OK) {
        set_error(node, "mqtt request failed");
    }
}

static void mqtt_state_publish_cb(void *arg, err_t err) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    if (err != ERR_OK && node) {
        set_errorf(node, "mqtt state publish cb failed", err);
    }
}

static void handle_command_message(mqtt_node_t *node, const char *payload) {
    char command[32] = {0};
    char command_id[64] = {0};
    char target_node_id[VG_MAX_NODE_ID_LEN] = {0};
    bool targeted = extract_json_string(payload, "node_id", target_node_id, sizeof(target_node_id));

    if (!extract_json_string(payload, "command", command, sizeof(command)) ||
        !extract_json_string(payload, "command_id", command_id, sizeof(command_id))) {
        set_error(node, "invalid command payload");
        return;
    }

    if (targeted && target_node_id[0] != '\0' && strcmp(target_node_id, node->config->node_id) != 0) {
        return;
    }

    if (strcmp(command, "request_reading") == 0) {
        snprintf(g_runtime.pending_command, sizeof(g_runtime.pending_command), "%s", command);
        snprintf(g_runtime.pending_command_id, sizeof(g_runtime.pending_command_id), "%s", command_id);
        snprintf(g_runtime.pending_command_status, sizeof(g_runtime.pending_command_status), "%s", "acknowledged");
        g_runtime.pending_command_ack = true;
        g_runtime.pending_publish_request = true;
        g_runtime.publish_request_needs_command_clear = true;
        set_error(node, "none");
    } else if (strcmp(command, "reboot") == 0) {
        snprintf(g_runtime.pending_command, sizeof(g_runtime.pending_command), "%s", command);
        snprintf(g_runtime.pending_command_id, sizeof(g_runtime.pending_command_id), "%s", command_id);
        snprintf(g_runtime.pending_command_status, sizeof(g_runtime.pending_command_status), "%s", "acknowledged");
        g_runtime.pending_command_ack = true;
        g_runtime.pending_reboot = true;
        set_error(node, "none");
    } else {
        snprintf(g_runtime.pending_command, sizeof(g_runtime.pending_command), "%s", command);
        snprintf(g_runtime.pending_command_id, sizeof(g_runtime.pending_command_id), "%s", command_id);
        snprintf(g_runtime.pending_command_status, sizeof(g_runtime.pending_command_status), "%s", "ignored");
        g_runtime.pending_command_ack = true;
    }
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
        // Broker-retained node config is the source of truth for zone/crop settings.
        // Applying it in memory avoids flash writes while the MQTT/Wi-Fi stack is active.
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
        snprintf(g_runtime.pending_config_payload,
                 sizeof(g_runtime.pending_config_payload),
                 "%s",
                 g_runtime.incoming_payload);
        g_runtime.pending_config_apply = true;
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
    if (g_runtime.incoming_topic[0] == '\0') {
        return;
    }
    if (data && g_runtime.incoming_payload_len + len >= sizeof(g_runtime.incoming_payload)) {
        set_error(node, "incoming payload too large");
        g_runtime.incoming_topic[0] = '\0';
        g_runtime.incoming_payload_len = 0;
        return;
    }
    if (data && len > 0) {
        memcpy(g_runtime.incoming_payload + g_runtime.incoming_payload_len, data, len);
        g_runtime.incoming_payload_len += len;
    }
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
    g_runtime.connected = (status == MQTT_CONNECT_ACCEPTED);
    if (g_runtime.connected) {
        mqtt_close_broker_discovery();
        g_runtime.next_reconnect_at = get_absolute_time();
        g_runtime.subscriptions_pending = true;
        set_error(node, "none");
    } else {
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
    snprintf(g_runtime.client_id, sizeof(g_runtime.client_id), "sensor-%s", node->config->node_id);
    info.client_id = g_runtime.client_id;
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
        g_runtime.next_reconnect_at = make_timeout_time_ms(15000);
    }
}

static void mqtt_finish_connect(mqtt_node_t *node) {
    if (!g_runtime.subscriptions_pending || !g_runtime.client || !mqtt_client_is_connected(g_runtime.client)) {
        return;
    }

    mqtt_set_inpub_callback(g_runtime.client, mqtt_incoming_publish_cb, mqtt_incoming_data_cb, node);
    subscribe_topics(node);
    g_runtime.subscriptions_pending = false;
    printf("[mqtt] subscriptions ready\n");
}

static void mqtt_flush_deferred_actions(mqtt_node_t *node) {
    if (!g_runtime.client || !mqtt_client_is_connected(g_runtime.client)) {
        return;
    }

    if (g_runtime.pending_config_apply) {
        handle_config_message(node, g_runtime.pending_config_payload);
        g_runtime.pending_config_apply = false;
    }

    if (g_runtime.pending_command_ack) {
        if (publish_command_ack(
                node,
                g_runtime.pending_command,
                g_runtime.pending_command_id,
                g_runtime.pending_command_status)) {
            g_runtime.pending_command_ack = false;
        }
    }

    if (g_runtime.pending_clear_retained_command) {
        if (clear_retained_command(node)) {
            g_runtime.pending_clear_retained_command = false;
        }
    }

    if (g_runtime.pending_publish_request) {
        node->publish_requested = true;
        g_runtime.pending_publish_request = false;
    }

    if (g_runtime.pending_reboot && !g_runtime.pending_command_ack) {
        node->reboot_requested = true;
        g_runtime.pending_reboot = false;
    }
}

void mqtt_node_poll(mqtt_node_t *node) {
    mqtt_ensure_connected(g_runtime.node);
    mqtt_finish_connect(g_runtime.node);
    mqtt_flush_deferred_actions(g_runtime.node);
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

    int32_t rssi = wifi_rssi();
    bool has_ip = wifi_ip_string(g_runtime.tx_ip, sizeof(g_runtime.tx_ip));
    topic_state(node->config, g_runtime.tx_topic, sizeof(g_runtime.tx_topic));
    time_sync_format_iso8601(g_runtime.tx_timestamp, sizeof(g_runtime.tx_timestamp));

    if (has_ip) {
        snprintf(
            g_runtime.tx_payload,
            sizeof(g_runtime.tx_payload),
            "{\"schema_version\":\"node-state/v1\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"moisture_raw\":%u,\"moisture_percent\":%d,\"soil_temp_c\":null,\"battery_voltage\":null,\"battery_percent\":null,\"wifi_rssi\":%ld,\"uptime_seconds\":%lu,\"wake_count\":%lu,\"ip\":\"%s\",\"health\":\"%s\",\"last_error\":\"%s\",\"publish_reason\":\"%s\"}",
            g_runtime.tx_timestamp,
            node->config->zone_id,
            node->config->node_id,
            snapshot->moisture_raw,
            snapshot->moisture_percent,
            (long)rssi,
            (unsigned long)(to_ms_since_boot(get_absolute_time()) / 1000u),
            (unsigned long)(to_ms_since_boot(get_absolute_time()) / 1000u),
            g_runtime.tx_ip,
            snapshot->healthy ? "ok" : "degraded",
            node->last_error,
            reason
        );
    } else {
        snprintf(
            g_runtime.tx_payload,
            sizeof(g_runtime.tx_payload),
            "{\"schema_version\":\"node-state/v1\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"moisture_raw\":%u,\"moisture_percent\":%d,\"soil_temp_c\":null,\"battery_voltage\":null,\"battery_percent\":null,\"wifi_rssi\":%ld,\"uptime_seconds\":%lu,\"wake_count\":%lu,\"ip\":null,\"health\":\"%s\",\"last_error\":\"%s\",\"publish_reason\":\"%s\"}",
            g_runtime.tx_timestamp,
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

    topic_state(node->config, g_runtime.tx_topic, sizeof(g_runtime.tx_topic));
    size_t payload_len = strlen(g_runtime.tx_payload);
    err_t err = mqtt_publish_locked(
        g_runtime.client,
        g_runtime.tx_topic,
        g_runtime.tx_payload,
        (u16_t)payload_len,
        0,
        1,
        mqtt_state_publish_cb,
        node);
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

bool mqtt_node_has_publish_request(const mqtt_node_t *node) {
    return node && node->publish_requested;
}

bool mqtt_node_take_publish_request(mqtt_node_t *node) {
    bool requested = node->publish_requested;
    node->publish_requested = false;
    return requested;
}

bool mqtt_node_take_reconnect_request(mqtt_node_t *node) {
    bool requested = node->config_changed_requires_reconnect;
    node->config_changed_requires_reconnect = false;
    return requested;
}

bool mqtt_node_take_reboot_request(mqtt_node_t *node) {
    bool requested = node->reboot_requested;
    node->reboot_requested = false;
    return requested;
}

void mqtt_node_mark_publish_request_handled(mqtt_node_t *node) {
    (void)node;
    if (g_runtime.publish_request_needs_command_clear) {
        g_runtime.pending_clear_retained_command = true;
        g_runtime.publish_request_needs_command_clear = false;
    }
}
