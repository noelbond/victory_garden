#include "mqtt_node.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "lwip/ip.h"
#include "lwip/apps/mqtt.h"
#include "lwip/ip4_addr.h"
#include "lwip/ip_addr.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/udp.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "json_lite.h"
#include "sensor_state_payload.h"
#include "time_sync.h"
#include "topics.h"
#include "wifi.h"

#define MQTT_RX_TOPIC_MAX 128
#define MQTT_RX_PAYLOAD_MAX 2048
#define MQTT_TX_PAYLOAD_MAX 2048
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
    // Discovery replies are unauthenticated, so a changed host/port is held
    // here as an unverified candidate (see mqtt_apply_discovered_broker())
    // rather than trusted immediately -- fallback_host/port is what to
    // revert to if the candidate never accepts our real MQTT credentials.
    bool broker_candidate_pending;
    char broker_fallback_host[VG_MAX_HOST_LEN];
    uint16_t broker_fallback_port;
    // Accumulated while unable to reach the configured broker, flushed as
    // one summary diagnostic event once reconnected (same host recovering,
    // or discovery finding it at a new one) instead of reporting every
    // individual retry/timeout -- see queue_broker_outage_diagnostic_event().
    bool broker_outage_active;
    absolute_time_t broker_outage_started_at;
    uint32_t broker_outage_no_response_count;
    uint32_t broker_outage_rejected_count;
    char broker_outage_last_rejected_host[VG_MAX_HOST_LEN];
    uint16_t broker_outage_last_rejected_port;
    bool pending_diagnostic_event;
    char pending_diagnostic_event_code[32];
    char pending_diagnostic_event_detail[192];
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
    // Reboot is handled through dedicated state, deliberately kept separate
    // from pending_command/pending_command_ack (shared by every other
    // command) and immune to mqtt_node_disconnect()'s reset, so a reboot
    // that has been accepted can never be silently displaced by a later
    // command or a reconnect racing it.
    char reboot_command_id[64];
    bool reboot_ack_pending;
    bool reboot_armed;
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
static void set_error(mqtt_node_t *node, const char *message);

static bool format_tx_payload(mqtt_node_t *node, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int written = vsnprintf(g_runtime.tx_payload, sizeof(g_runtime.tx_payload), fmt, args);
    va_end(args);

    if (written < 0) {
        set_error(node, "mqtt payload format failed");
        return false;
    }

    if ((size_t)written >= sizeof(g_runtime.tx_payload)) {
        set_error(node, "mqtt payload buffer too small");
        return false;
    }

    return true;
}

static void set_error(mqtt_node_t *node, const char *message) {
    snprintf(node->last_error, sizeof(node->last_error), "%s", message ? message : "none");
}

// Network-supplied strings (e.g. a discovery reply's claimed host) get
// embedded into this file's hand-rolled JSON elsewhere, which is not
// escaping-aware -- a malicious or malformed value containing a quote or
// backslash could break the resulting payload's structure. Used wherever an
// untrusted string needs to go into an outgoing JSON string field.
static void sanitize_for_json_detail(const char *src, char *out, size_t out_size) {
    if (!out || out_size == 0) {
        return;
    }
    size_t len = 0;
    for (; src && src[len] != '\0' && len + 1 < out_size; ++len) {
        char ch = src[len];
        out[len] = (ch == '"' || ch == '\\' || (unsigned char)ch < 0x20) ? '_' : ch;
    }
    out[len] = '\0';
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

    if (!changed) {
        g_runtime.next_reconnect_at = get_absolute_time();
        set_error(node, "none");
        return;
    }

    // Discovery replies are unauthenticated -- anyone on the LAN broadcast
    // domain can answer. Apply this as an unverified candidate and keep the
    // current host/port to revert to; mqtt_connection_cb() only persists it
    // once it's confirmed by actually accepting our real MQTT credentials.
    snprintf(g_runtime.broker_fallback_host, sizeof(g_runtime.broker_fallback_host), "%s", node->config->mqtt_host);
    g_runtime.broker_fallback_port = node->config->mqtt_port;
    snprintf(node->config->mqtt_host, sizeof(node->config->mqtt_host), "%s", g_runtime.discovered_mqtt_host);
    node->config->mqtt_port = g_runtime.discovered_mqtt_port;
    g_runtime.broker_candidate_pending = true;
    printf("[mqtt] broker candidate host=%s port=%u (unverified, from discovery) -- will persist only if it accepts our credentials\n",
           node->config->mqtt_host,
           (unsigned)node->config->mqtt_port);

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
        if (g_runtime.broker_outage_active) {
            g_runtime.broker_outage_no_response_count++;
        }
    }

    if (!g_runtime.discovery_in_progress) {
        mqtt_start_broker_discovery(node);
    }
}

static bool topic_equals(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

static bool node_id_matches_config(const node_config_t *config, const char *node_id) {
    if (!config || !node_id || node_id[0] == '\0') {
        return false;
    }

    if (strcmp(node_id, config->node_id) == 0) {
        return true;
    }

    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        if (strcmp(node_id, config->channel_node_id[channel]) == 0) {
            return true;
        }
    }

    return false;
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

    if (!format_tx_payload(
            node,
            "{\"schema_version\":\"node-command-ack/v1\",\"zone_id\":\"%s\",\"node_id\":\"%s\",\"command\":\"%s\",\"command_id\":\"%s\",\"status\":\"%s\"}",
            node->config->zone_id,
            node->config->node_id,
            command,
            command_id,
            status)) {
        return false;
    }
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
        if (!format_tx_payload(
                node,
                "{\"schema_version\":\"node-config-ack/v1\",\"node_id\":\"%s\",\"config_version\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"applied_config\":{\"assigned\":true,\"zone_id\":\"%s\",\"crop_id\":\"%s\"},\"error\":%s}",
                node->config->node_id,
                node->config->config_version,
                status,
                g_runtime.tx_timestamp,
                node->config->zone_id,
                node->config->zone_id,
                node->config->crop_id,
                error_message ? error_message : "null")) {
            return;
        }
    } else {
        if (!format_tx_payload(
                node,
                "{\"schema_version\":\"node-config-ack/v1\",\"node_id\":\"%s\",\"config_version\":\"%s\",\"status\":\"%s\",\"timestamp\":\"%s\",\"zone_id\":\"%s\",\"applied_config\":{\"assigned\":false},\"error\":%s}",
                node->config->node_id,
                node->config->config_version,
                status,
                g_runtime.tx_timestamp,
                node->config->zone_id,
                error_message ? error_message : "null")) {
            return;
        }
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

// One-shot informational events (currently: broker-outage summaries) that
// don't fit the routine sensor-state schema. Not retained -- a stale
// diagnostic event replayed to a late subscriber would be actively
// misleading, unlike current-state topics where retain is intentional.
static bool publish_node_diagnostic_event(mqtt_node_t *node, const char *event_code, const char *detail) {
    topic_node_diagnostic_event(node->config, g_runtime.tx_topic, sizeof(g_runtime.tx_topic));
    time_sync_format_iso8601(g_runtime.tx_timestamp, sizeof(g_runtime.tx_timestamp));

    if (!format_tx_payload(
            node,
            "{\"schema_version\":\"node-diagnostic-event/v1\",\"node_id\":\"%s\",\"zone_id\":\"%s\",\"event_code\":\"%s\",\"detail\":\"%s\",\"timestamp\":\"%s\"}",
            node->config->node_id,
            node->config->zone_id,
            event_code,
            detail,
            g_runtime.tx_timestamp)) {
        return false;
    }

    err_t err = mqtt_publish_locked(
        g_runtime.client,
        g_runtime.tx_topic,
        g_runtime.tx_payload,
        (u16_t)strlen(g_runtime.tx_payload),
        1,
        0,
        mqtt_request_cb,
        node);
    if (err == ERR_OK) {
        return true;
    }

    if (err == ERR_MEM) {
        set_error(node, "mqtt diagnostic event buffer full");
    } else {
        set_errorf(node, "mqtt diagnostic event failed", err);
    }
    return false;
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

    if (!payload || payload[0] == '\0') {
        return;
    }

    // A reboot that has already been accepted always wins: ignore every
    // other incoming command rather than let it disturb shared ack state
    // while the reboot is still in flight.
    if (g_runtime.reboot_ack_pending || g_runtime.reboot_armed) {
        return;
    }

    bool targeted = extract_json_string(payload, "node_id", target_node_id, sizeof(target_node_id));

    if (!extract_json_string(payload, "command", command, sizeof(command)) ||
        !extract_json_string(payload, "command_id", command_id, sizeof(command_id))) {
        set_error(node, "invalid command payload");
        return;
    }

    if (targeted && target_node_id[0] != '\0' && !node_id_matches_config(node->config, target_node_id)) {
        return;
    }

    if (strcmp(command, "reboot") == 0) {
        snprintf(g_runtime.reboot_command_id, sizeof(g_runtime.reboot_command_id), "%s", command_id);
        g_runtime.reboot_ack_pending = true;
        set_error(node, "none");
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

static void broker_outage_note_started(void) {
    if (g_runtime.broker_outage_active) {
        return;
    }
    g_runtime.broker_outage_active = true;
    g_runtime.broker_outage_started_at = get_absolute_time();
    g_runtime.broker_outage_no_response_count = 0;
    g_runtime.broker_outage_rejected_count = 0;
    g_runtime.broker_outage_last_rejected_host[0] = '\0';
    g_runtime.broker_outage_last_rejected_port = 0;
}

// Reverts an unverified candidate to the last-known-good host, whether it
// was rejected via a CONNACK failure or never even reached that point (e.g.
// it wasn't a parseable IP). Callers are responsible for having already
// called broker_outage_note_started() -- this only handles the revert and
// the rejection-specific counters.
static void mqtt_reject_broker_candidate(node_config_t *config) {
    g_runtime.broker_outage_rejected_count++;
    sanitize_for_json_detail(config->mqtt_host, g_runtime.broker_outage_last_rejected_host,
                              sizeof(g_runtime.broker_outage_last_rejected_host));
    g_runtime.broker_outage_last_rejected_port = config->mqtt_port;
    printf("[mqtt] broker candidate host=%s port=%u rejected, reverting to host=%s port=%u\n",
           config->mqtt_host, (unsigned)config->mqtt_port,
           g_runtime.broker_fallback_host, (unsigned)g_runtime.broker_fallback_port);
    snprintf(config->mqtt_host, sizeof(config->mqtt_host), "%s", g_runtime.broker_fallback_host);
    config->mqtt_port = g_runtime.broker_fallback_port;
    g_runtime.broker_candidate_pending = false;
}

// Called once a connection succeeds, if an outage was being tracked --
// builds a single summary event covering however long it took and whatever
// happened along the way, rather than reporting each retry/timeout
// individually. event_code is chosen by priority (a rejected candidate is
// the most notable fact if one occurred, since it may indicate spoofing;
// otherwise whether discovery actually relocated the broker; otherwise
// whether discovery ran at all) but the full stats always go in detail
// regardless of which code wins, so nothing is lost either way.
static void queue_broker_outage_diagnostic_event(bool discovery_applied) {
    uint32_t duration_s = (uint32_t)(absolute_time_diff_us(g_runtime.broker_outage_started_at, get_absolute_time()) / 1000000);
    const char *event_code;
    if (g_runtime.broker_outage_rejected_count > 0) {
        event_code = "BROKER_DISCOVERY_REJECTED";
    } else if (discovery_applied) {
        event_code = "BROKER_DISCOVERY_APPLIED";
    } else if (g_runtime.broker_outage_no_response_count > 0) {
        event_code = "BROKER_DISCOVERY_NO_RESPONSE";
    } else {
        event_code = "BROKER_UNREACHABLE";
    }

    snprintf(g_runtime.pending_diagnostic_event_code, sizeof(g_runtime.pending_diagnostic_event_code), "%s", event_code);
    snprintf(
        g_runtime.pending_diagnostic_event_detail,
        sizeof(g_runtime.pending_diagnostic_event_detail),
        "unreachable for %lus; discovery_no_response=%lu discovery_rejected=%lu last_rejected=%s:%u",
        (unsigned long)duration_s,
        (unsigned long)g_runtime.broker_outage_no_response_count,
        (unsigned long)g_runtime.broker_outage_rejected_count,
        g_runtime.broker_outage_rejected_count > 0 ? g_runtime.broker_outage_last_rejected_host : "none",
        (unsigned)(g_runtime.broker_outage_rejected_count > 0 ? g_runtime.broker_outage_last_rejected_port : 0)
    );
    g_runtime.pending_diagnostic_event = true;

    g_runtime.broker_outage_active = false;
    g_runtime.broker_outage_no_response_count = 0;
    g_runtime.broker_outage_rejected_count = 0;
    g_runtime.broker_outage_last_rejected_host[0] = '\0';
    g_runtime.broker_outage_last_rejected_port = 0;
}

static void mqtt_connection_cb(mqtt_client_t *client, void *arg, mqtt_connection_status_t status) {
    mqtt_node_t *node = (mqtt_node_t *)arg;
    (void)client;
    printf("[mqtt_cb] status=%d\n", (int)status);
    g_runtime.connected = (status == MQTT_CONNECT_ACCEPTED);
    if (g_runtime.connected) {
        bool discovery_applied_this_connect = g_runtime.broker_candidate_pending;
        if (g_runtime.broker_candidate_pending) {
            // The candidate just accepted our real MQTT credentials -- that
            // confirmation is what discovery alone can't provide. Safe to
            // make it permanent now.
            g_runtime.broker_candidate_pending = false;
            char save_error[64];
            if (!node_config_save(node->config, save_error, sizeof(save_error))) {
                printf("[mqtt] broker candidate save failed: %s\n", save_error);
            } else {
                printf("[mqtt] broker candidate host=%s port=%u verified and saved\n",
                       node->config->mqtt_host, (unsigned)node->config->mqtt_port);
            }
        }
        if (g_runtime.broker_outage_active) {
            queue_broker_outage_diagnostic_event(discovery_applied_this_connect);
        }
        mqtt_close_broker_discovery();
        g_runtime.next_reconnect_at = get_absolute_time();
        g_runtime.subscriptions_pending = true;
        set_error(node, "none");
    } else {
        printf("[mqtt_cb] not accepted - status=%d\n", (int)status);
        set_error(node, "mqtt disconnected");
        g_runtime.next_reconnect_at = make_timeout_time_ms(5000);
        broker_outage_note_started();
        if (g_runtime.broker_candidate_pending) {
            // Candidate was rejected (or unreachable) -- revert to the
            // last-known-good host rather than getting stuck retrying a bad
            // or spoofed one, and leave discovery_next_attempt_at alone so
            // the restored fallback gets a real shot on the normal
            // reconnect cadence before we rebroadcast again.
            mqtt_reject_broker_candidate(node->config);
        } else {
            g_runtime.discovery_next_attempt_at = get_absolute_time();
        }
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
        // A discovery candidate that isn't even a parseable IP never reaches
        // mqtt_client_connect_locked(), so mqtt_connection_cb() would never
        // fire to revert it -- without this, a malformed candidate host
        // would get stuck applied in RAM (never flash-saved, but never
        // un-applied either) instead of being rejected like every other bad
        // candidate.
        broker_outage_note_started();
        if (g_runtime.broker_candidate_pending) {
            mqtt_reject_broker_candidate(node->config);
        }
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

    // Reboot takes priority over every other deferred action: ack and arm it
    // before touching config apply, other command acks, or publish
    // requests, so nothing queued behind it can delay or displace it.
    if (g_runtime.reboot_ack_pending) {
        if (publish_command_ack(node, "reboot", g_runtime.reboot_command_id, "acknowledged")) {
            g_runtime.reboot_ack_pending = false;
            g_runtime.reboot_armed = true;
        }
    }

    if (g_runtime.reboot_armed) {
        node->reboot_requested = true;
        g_runtime.reboot_armed = false;
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

    if (g_runtime.pending_diagnostic_event) {
        if (publish_node_diagnostic_event(node, g_runtime.pending_diagnostic_event_code, g_runtime.pending_diagnostic_event_detail)) {
            g_runtime.pending_diagnostic_event = false;
        }
    }
}

void mqtt_node_poll(mqtt_node_t *node) {
    mqtt_ensure_connected(g_runtime.node);
    mqtt_finish_connect(g_runtime.node);
    mqtt_flush_deferred_actions(g_runtime.node);
}

void mqtt_node_disconnect(mqtt_node_t *node) {
    if (g_runtime.discovery_in_progress || g_runtime.discovery_pcb) {
        mqtt_close_broker_discovery();
    }

    if (g_runtime.client) {
        if (mqtt_client_is_connected(g_runtime.client)) {
            cyw43_arch_lwip_begin();
            mqtt_disconnect(g_runtime.client);
            cyw43_arch_lwip_end();
        }

        cyw43_arch_lwip_begin();
        mqtt_client_free(g_runtime.client);
        cyw43_arch_lwip_end();
    }

    if (g_runtime.broker_candidate_pending && node) {
        // An unverified discovery candidate never got confirmed before this
        // disconnect (e.g. a zone reassignment forced it) -- revert rather
        // than carry an unconfirmed host across the reconnect.
        snprintf(node->config->mqtt_host, sizeof(node->config->mqtt_host), "%s", g_runtime.broker_fallback_host);
        node->config->mqtt_port = g_runtime.broker_fallback_port;
    }
    g_runtime.broker_candidate_pending = false;

    g_runtime.client = NULL;
    g_runtime.connected = false;
    g_runtime.subscriptions_pending = false;
    g_runtime.discovery_in_progress = false;
    g_runtime.discovery_resolved = false;
    g_runtime.discovery_pcb = NULL;
    g_runtime.discovered_mqtt_host[0] = '\0';
    g_runtime.discovered_mqtt_port = 0;
    g_runtime.pending_command_ack = false;
    g_runtime.pending_clear_retained_command = false;
    g_runtime.pending_publish_request = false;
    g_runtime.publish_request_needs_command_clear = false;
    g_runtime.pending_config_apply = false;
    g_runtime.incoming_payload_len = 0;
    g_runtime.incoming_topic[0] = '\0';
    g_runtime.incoming_payload[0] = '\0';
    g_runtime.pending_config_payload[0] = '\0';
    g_runtime.pending_command[0] = '\0';
    g_runtime.pending_command_id[0] = '\0';
    g_runtime.pending_command_status[0] = '\0';
    g_runtime.next_reconnect_at = get_absolute_time();
    g_runtime.discovery_next_attempt_at = get_absolute_time();
    g_runtime.discovery_deadline = get_absolute_time();

    // reboot_ack_pending/reboot_armed are deliberately NOT reset here: once a
    // reboot has been accepted it must survive any reconnect that races it,
    // rather than being silently dropped by this reset.

    if (node) {
        set_error(node, "none");
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

bool mqtt_node_publish_state(mqtt_node_t *node, const sensor_snapshot_t *snapshot, const char *reason, uint32_t wake_count, const char *node_id) {
    if (!mqtt_node_is_connected(node)) {
        set_error(node, "mqtt not connected");
        return false;
    }

    const char *publish_node_id = (node_id && node_id[0] != '\0') ? node_id : node->config->node_id;
    node_config_t topic_config = *node->config;
    snprintf(topic_config.node_id, sizeof(topic_config.node_id), "%s", publish_node_id);

    int32_t rssi = wifi_rssi();
    bool has_ip = wifi_ip_string(g_runtime.tx_ip, sizeof(g_runtime.tx_ip));
    topic_state(&topic_config, g_runtime.tx_topic, sizeof(g_runtime.tx_topic));
    time_sync_format_iso8601(g_runtime.tx_timestamp, sizeof(g_runtime.tx_timestamp));

    if (!sensor_state_payload_format(
            g_runtime.tx_payload,
            sizeof(g_runtime.tx_payload),
            node->config,
            snapshot,
            g_runtime.tx_timestamp,
            publish_node_id,
            reason,
            wake_count,
            (uint32_t)(to_ms_since_boot(get_absolute_time()) / 1000u),
            rssi,
            has_ip ? g_runtime.tx_ip : NULL,
            node->last_error)) {
        set_error(node, "mqtt payload buffer too small");
        return false;
    }

    topic_state(&topic_config, g_runtime.tx_topic, sizeof(g_runtime.tx_topic));
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
