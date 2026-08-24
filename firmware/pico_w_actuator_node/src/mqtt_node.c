#include "mqtt_node.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "hardware/gpio.h"
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
    char client_id[VG_MAX_NODE_ID_LEN + 10];
    size_t incoming_payload_len;
    uint16_t discovered_mqtt_port;
} mqtt_runtime_t;

static mqtt_runtime_t g_runtime;
static const uint8_t g_default_line_relay_gpios[VG_MAX_IRRIGATION_LINES] = VG_DEFAULT_IRRIGATION_LINE_RELAY_GPIOS;

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

static bool actuator_command_topic_match(const char *topic, char *zone_id, size_t zone_id_size) {
    const char *prefix = "greenhouse/zones/";
    const char *suffix = "/actuator/command";
    size_t prefix_len = strlen(prefix);
    size_t suffix_len = strlen(suffix);
    size_t topic_len = strlen(topic);

    if (topic_len <= prefix_len + suffix_len ||
        strncmp(topic, prefix, prefix_len) != 0 ||
        strcmp(topic + topic_len - suffix_len, suffix) != 0) {
        return false;
    }

    size_t zone_len = topic_len - prefix_len - suffix_len;
    if (zone_len == 0 || zone_len >= zone_id_size) {
        return false;
    }

    memcpy(zone_id, topic + prefix_len, zone_len);
    zone_id[zone_len] = '\0';
    return true;
}

static uint8_t line_gpio_for_index(const mqtt_node_t *node, size_t line_index) {
    if (line_index == 0) {
        return node->config->actuator_relay_gpio;
    }
    return g_default_line_relay_gpios[line_index];
}

void actuator_relays_init_safe(const node_config_t *config) {
    // gpio_init() leaves the pin as an input with its output latch at 0.
    // Preload the latch with the correct OFF level *before* switching to
    // output — otherwise, on an active-low relay board, the pin would
    // briefly drive LOW (relay ON) the instant gpio_set_dir(GPIO_OUT) takes
    // effect. This runs before Wi-Fi/MQTT so a relay is never left
    // undriven while the board reconnects, including after a watchdog reset.
    bool off_level = !config->actuator_relay_active_high;
    for (size_t i = 0; i < VG_MAX_IRRIGATION_LINES; ++i) {
        uint8_t gpio = (i == 0) ? config->actuator_relay_gpio : g_default_line_relay_gpios[i];
        gpio_init(gpio);
        gpio_put(gpio, off_level ? 1u : 0u);
        gpio_set_dir(gpio, GPIO_OUT);
    }
    printf("[actuator] relays forced to safe OFF level pre-network active_high=%d\n",
           (int)config->actuator_relay_active_high);
    stdio_flush();
}

static actuator_zone_assignment_t *assignment_for_zone(mqtt_node_t *node, const char *zone_id) {
    for (size_t i = 0; i < VG_MAX_IRRIGATION_LINES; ++i) {
        if (node->assignments[i].assigned &&
            node->assignments[i].node_id[0] == '\0' &&
            strcmp(node->assignments[i].zone_id, zone_id) == 0) {
            return &node->assignments[i];
        }
    }
    return NULL;
}

static actuator_zone_assignment_t *assignment_for_node(mqtt_node_t *node, const char *node_id) {
    if (!node_id || node_id[0] == '\0') {
        return NULL;
    }

    for (size_t i = 0; i < VG_MAX_IRRIGATION_LINES; ++i) {
        if (node->assignments[i].assigned && strcmp(node->assignments[i].node_id, node_id) == 0) {
            return &node->assignments[i];
        }
    }
    return NULL;
}

static actuator_line_run_t *run_for_line(mqtt_node_t *node, uint8_t irrigation_line) {
    if (irrigation_line == 0 || irrigation_line > VG_MAX_IRRIGATION_LINES) {
        return NULL;
    }
    return &node->runs[irrigation_line - 1u];
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

static void actuator_set_line_output(mqtt_node_t *node, uint8_t irrigation_line, bool enabled) {
    if (irrigation_line == 0 || irrigation_line > VG_MAX_IRRIGATION_LINES) {
        return;
    }

    size_t line_index = irrigation_line - 1u;
    uint8_t gpio = line_gpio_for_index(node, line_index);
    bool level = enabled ? node->config->actuator_relay_active_high : !node->config->actuator_relay_active_high;
    gpio_put(gpio, level ? 1u : 0u);
    printf("[actuator] line=%u relay_gp=%u enabled=%d level=%d\n",
           (unsigned)irrigation_line,
           (unsigned)gpio,
           (int)enabled,
           (int)level);
}

// Runs from an alarm IRQ, independent of the main loop. Must stay minimal —
// no MQTT/lwIP calls, no touching node/g_runtime, nothing that can block or
// isn't IRQ-safe. gpio/off_level were snapshotted at schedule time
// specifically so this callback never needs to dereference node->config.
// The main loop's own hard_deadline check (mqtt_node_poll) still runs the
// normal stop/publish/cleanup once it next gets a chance to run — this is
// only the safety-critical "physically turn it off now" backstop.
static int64_t actuator_hw_cutoff_callback(alarm_id_t id, void *user_data) {
    (void)id;
    actuator_line_run_t *run = (actuator_line_run_t *)user_data;
    gpio_put(run->cutoff_gpio, run->cutoff_off_level ? 1u : 0u);
    run->hardware_cutoff_fired = true;
    return 0;
}

static uint32_t actuator_elapsed_seconds(const actuator_line_run_t *run) {
    uint32_t now_ms = to_ms_since_boot(get_absolute_time());
    if (now_ms <= run->started_at_ms) {
        return 0u;
    }
    return (now_ms - run->started_at_ms) / 1000u;
}

static bool mqtt_publish_actuator_status_now(mqtt_node_t *node, const char *zone_id, const char *node_id, const char *idempotency_key,
                                             const actuator_line_run_t *run, actuator_status_t status,
                                             const char *fault_code, const char *fault_detail) {
    if (!g_runtime.connected || !g_runtime.client || !mqtt_client_is_connected(g_runtime.client)) {
        return false;
    }

    char topic[MQTT_RX_TOPIC_MAX];
    char timestamp[32];
    char payload[MQTT_TX_PAYLOAD_MAX];
    char actual_runtime_json[24];
    char node_id_json[VG_MAX_NODE_ID_LEN + 4];
    char fault_code_json[64];
    char fault_detail_json[160];
    topic_actuator_status_for_zone(zone_id, topic, sizeof(topic));
    time_sync_format_iso8601(timestamp, sizeof(timestamp));

    if (status == ACTUATOR_STATUS_ACKNOWLEDGED) {
        snprintf(actual_runtime_json, sizeof(actual_runtime_json), "null");
    } else {
        snprintf(actual_runtime_json, sizeof(actual_runtime_json), "%lu",
                 (unsigned long)(run ? actuator_elapsed_seconds(run) : 0u));
    }

    if (node_id && node_id[0] != '\0') {
        snprintf(node_id_json, sizeof(node_id_json), "\"%s\"", node_id);
    } else if (run && run->node_id[0] != '\0') {
        snprintf(node_id_json, sizeof(node_id_json), "\"%s\"", run->node_id);
    } else {
        snprintf(node_id_json, sizeof(node_id_json), "null");
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
        "{\"zone_id\":\"%s\",\"node_id\":%s,\"state\":\"%s\",\"timestamp\":\"%s\",\"idempotency_key\":\"%s\",\"actual_runtime_seconds\":%s,\"flow_ml\":null,\"fault_code\":%s,\"fault_detail\":%s}",
        zone_id,
        node_id_json,
        actuator_status_name(status),
        timestamp,
        idempotency_key,
        actual_runtime_json,
        fault_code_json,
        fault_detail_json
    );

    u8_t qos = (status == ACTUATOR_STATUS_COMPLETED || status == ACTUATOR_STATUS_FAULT) ? 1 : 0;
    err_t err = mqtt_publish_locked(g_runtime.client, topic, payload, (u16_t)strlen(payload), qos, 1, mqtt_request_cb, node);
    if (err == ERR_OK) {
        set_error(node, "none");
        return true;
    }

    if (err == ERR_MEM) {
        set_error(node, "mqtt actuator status buffer full");
    } else {
        set_errorf(node, "mqtt actuator status failed", err);
    }
    return false;
}

static void actuator_stop_with_status(mqtt_node_t *node, actuator_line_run_t *run, uint8_t irrigation_line,
                                      actuator_status_t status,
                                      const char *fault_code, const char *fault_detail) {
    printf("[actuator] stop zone=%s line=%u status=%s fault=%s hw_cutoff_fired=%d\n",
           run ? run->zone_id : "unknown",
           (unsigned)irrigation_line,
           actuator_status_name(status),
           fault_code ? fault_code : "none",
           run ? (int)run->hardware_cutoff_fired : 0);
    actuator_set_line_output(node, irrigation_line, false);
    if (run) {
        // Every path that ends a run — manual stop, the software deadline
        // check below, or this being called after the hardware alarm
        // already fired — comes through here, so this is the one place
        // that must cancel any outstanding alarm before the slot is
        // cleared for reuse. Otherwise a stale alarm from THIS run could
        // fire later and cut off a completely different run started on the
        // same line afterward. Harmless no-op if it already fired or was
        // never scheduled.
        if (run->cutoff_alarm_id > 0) {
            cancel_alarm(run->cutoff_alarm_id);
        }
        mqtt_publish_actuator_status_now(node, run->zone_id, run->node_id, run->idempotency_key, run, status, fault_code, fault_detail);
        memset(run, 0, sizeof(*run));
    }
}

static void clear_retained_topic(const char *topic) {
    mqtt_publish_locked(g_runtime.client, topic, "", 0, 0, 1, NULL, NULL);
}

static void clear_retained_actuator_command(const char *zone_id) {
    char topic[MQTT_RX_TOPIC_MAX];
    topic_actuator_command_for_zone(zone_id, topic, sizeof(topic));
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

// One-shot informational events (currently: broker-outage summaries) that
// don't fit the routine actuator-status schema. Not retained -- a stale
// diagnostic event replayed to a late subscriber would be actively
// misleading, unlike current-state topics where retain is intentional.
static bool publish_node_diagnostic_event(mqtt_node_t *node, const char *event_code, const char *detail) {
    char topic[MQTT_RX_TOPIC_MAX];
    char payload[MQTT_TX_PAYLOAD_MAX];
    char timestamp[32];
    topic_node_diagnostic_event(node->config, topic, sizeof(topic));
    time_sync_format_iso8601(timestamp, sizeof(timestamp));

    int written = snprintf(
        payload,
        sizeof(payload),
        "{\"schema_version\":\"node-diagnostic-event/v1\",\"node_id\":\"%s\",\"zone_id\":\"%s\",\"event_code\":\"%s\",\"detail\":\"%s\",\"timestamp\":\"%s\"}",
        node->config->node_id,
        node->config->zone_id,
        event_code,
        detail,
        timestamp
    );
    if (written < 0 || (size_t)written >= sizeof(payload)) {
        set_error(node, "mqtt diagnostic event payload too large");
        return false;
    }

    err_t err = mqtt_publish_locked(g_runtime.client, topic, payload, (u16_t)strlen(payload), 1, 0, mqtt_request_cb, node);
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

static bool zone_id_already_seen(const char (*seen)[VG_MAX_ZONE_ID_LEN], size_t seen_count, const char *zone_id) {
    for (size_t i = 0; i < seen_count; ++i) {
        if (strcmp(seen[i], zone_id) == 0) {
            return true;
        }
    }
    return false;
}

static void subscribe_assigned_zone_topics(mqtt_node_t *node) {
    if (!g_runtime.client || !g_runtime.connected || !mqtt_client_is_connected(g_runtime.client)) {
        return;
    }

    // Multiple irrigation lines are commonly assigned to the same zone, so
    // subscribe once per unique zone_id rather than once per line -- each
    // subscribe consumes one of MQTT_REQ_MAX_IN_FLIGHT request slots until
    // the broker's SUBACK arrives, and re-subscribing to the same topic
    // repeatedly back-to-back (up to VG_MAX_IRRIGATION_LINES=12 times) was
    // exhausting that pool.
    char seen_zone_ids[VG_MAX_IRRIGATION_LINES][VG_MAX_ZONE_ID_LEN];
    size_t seen_count = 0;

    for (size_t i = 0; i < VG_MAX_IRRIGATION_LINES; ++i) {
        const actuator_zone_assignment_t *assignment = &node->assignments[i];
        if (!assignment->assigned || assignment->zone_id[0] == '\0') {
            continue;
        }

        if (zone_id_already_seen(seen_zone_ids, seen_count, assignment->zone_id)) {
            continue;
        }

        char topic[MQTT_RX_TOPIC_MAX];
        topic_actuator_command_for_zone(assignment->zone_id, topic, sizeof(topic));
        err_t err = mqtt_subscribe_locked(g_runtime.client, topic, 0, mqtt_request_cb, node);
        printf("[mqtt] subscribe zone command topic=%s err=%d\n", topic, (int)err);
        if (err != ERR_OK) {
            set_error(node, "zone command subscribe failed");
        }

        snprintf(seen_zone_ids[seen_count], VG_MAX_ZONE_ID_LEN, "%s", assignment->zone_id);
        seen_count++;
    }
}

static void handle_actuator_config_message(mqtt_node_t *node, const char *payload) {
    char schema[32] = {0};
    int irrigation_line_count = 0;

    if (!extract_json_string(payload, "schema_version", schema, sizeof(schema)) ||
        strcmp(schema, "actuator-config/v1") != 0 ||
        !extract_json_int(payload, "irrigation_line_count", &irrigation_line_count) ||
        irrigation_line_count < 0) {
        set_error(node, "invalid actuator config");
        return;
    }

    if (irrigation_line_count > (int)VG_MAX_IRRIGATION_LINES) {
        irrigation_line_count = (int)VG_MAX_IRRIGATION_LINES;
    }

    memset(node->assignments, 0, sizeof(node->assignments));
    node->irrigation_line_count = (uint8_t)irrigation_line_count;

    const char *zones_array = strstr(payload, "\"zones\":[");
    if (zones_array) {
        const char *cursor = strchr(zones_array, '[');
        if (cursor) {
            ++cursor;
            const char *array_end = strchr(cursor, ']');
            while (array_end && (cursor = strstr(cursor, "{\"zone_id\":\"")) != NULL && cursor < array_end) {
                actuator_zone_assignment_t assignment = {0};
                const char *zone_start = cursor + strlen("{\"zone_id\":\"");
                const char *after_zone = NULL;
                int line_number = 0;
                bool active = false;

                if (!decode_json_string(zone_start, assignment.zone_id, sizeof(assignment.zone_id), &after_zone)) {
                    break;
                }

                const char *object_end = strchr(after_zone, '}');
                if (!object_end) {
                    break;
                }

                const char *line_field = strstr(after_zone, "\"irrigation_line\":");
                const char *active_field = strstr(after_zone, "\"active\":");
                if (!line_field || line_field > object_end || !extract_json_int(line_field, "irrigation_line", &line_number)) {
                    cursor = object_end + 1;
                    continue;
                }

                if (active_field && active_field < object_end) {
                    if (strncmp(active_field + strlen("\"active\":"), "true", 4) == 0) {
                        active = true;
                    }
                }

                if (line_number <= 0 || line_number > irrigation_line_count) {
                    cursor = object_end + 1;
                    continue;
                }

                assignment.assigned = true;
                assignment.active = active;
                assignment.irrigation_line = (uint8_t)line_number;
                node->assignments[line_number - 1] = assignment;
                printf("[actuator] config zone=%s line=%d active=%d\n",
                       assignment.zone_id,
                       line_number,
                       (int)active);
                cursor = object_end + 1;
            }
        }
    }

    const char *nodes_array = strstr(payload, "\"nodes\":[");
    if (nodes_array) {
        const char *cursor = strchr(nodes_array, '[');
        if (cursor) {
            ++cursor;
            const char *array_end = strchr(cursor, ']');
            while (array_end && (cursor = strstr(cursor, "{\"node_id\":\"")) != NULL && cursor < array_end) {
                actuator_zone_assignment_t assignment = {0};
                const char *node_start = cursor + strlen("{\"node_id\":\"");
                const char *after_node = NULL;
                int line_number = 0;
                bool active = false;

                if (!decode_json_string(node_start, assignment.node_id, sizeof(assignment.node_id), &after_node)) {
                    break;
                }

                const char *object_end = strchr(after_node, '}');
                if (!object_end || object_end > array_end) {
                    break;
                }

                const char *line_field = strstr(after_node, "\"irrigation_line\":");
                const char *active_field = strstr(after_node, "\"active\":");
                if (!line_field || line_field > object_end || !extract_json_int(line_field, "irrigation_line", &line_number)) {
                    cursor = object_end + 1;
                    continue;
                }

                if (!extract_json_string(after_node, "zone_id", assignment.zone_id, sizeof(assignment.zone_id))) {
                    cursor = object_end + 1;
                    continue;
                }

                if (active_field && active_field < object_end) {
                    if (strncmp(active_field + strlen("\"active\":"), "true", 4) == 0) {
                        active = true;
                    }
                }

                if (line_number <= 0 || line_number > irrigation_line_count) {
                    cursor = object_end + 1;
                    continue;
                }

                assignment.assigned = true;
                assignment.active = active;
                assignment.irrigation_line = (uint8_t)line_number;
                node->assignments[line_number - 1] = assignment;
                printf("[actuator] config node=%s zone=%s line=%d active=%d\n",
                       assignment.node_id,
                       assignment.zone_id,
                       line_number,
                       (int)active);
                cursor = object_end + 1;
            }
        }
    }

    printf("[actuator] config applied line_count=%u\n", (unsigned)node->irrigation_line_count);
    subscribe_assigned_zone_topics(node);
    set_error(node, "none");
}

static void handle_actuator_command_message(mqtt_node_t *node, const char *topic_zone_id, const char *payload) {
    char command[32] = {0};
    char idempotency_key[96] = {0};
    char payload_zone_id[VG_MAX_ZONE_ID_LEN] = {0};
    char payload_node_id[VG_MAX_NODE_ID_LEN] = {0};
    int runtime_seconds = 0;

    if (!payload || payload[0] == '\0') {
        set_error(node, "none");
        return;
    }

    if (!extract_json_string(payload, "command", command, sizeof(command)) ||
        !extract_json_string(payload, "idempotency_key", idempotency_key, sizeof(idempotency_key))) {
        set_error(node, "invalid actuator payload");
        return;
    }

    if (extract_json_string(payload, "zone_id", payload_zone_id, sizeof(payload_zone_id)) &&
        strcmp(payload_zone_id, topic_zone_id) != 0) {
        mqtt_publish_actuator_status_now(node, topic_zone_id, NULL, idempotency_key, NULL, ACTUATOR_STATUS_FAULT, "ZONE_MISMATCH", "topic zone_id does not match payload");
        set_error(node, "actuator zone mismatch");
        return;
    }
    extract_json_string(payload, "node_id", payload_node_id, sizeof(payload_node_id));

    clear_retained_actuator_command(topic_zone_id);

    actuator_zone_assignment_t *assignment = payload_node_id[0] != '\0'
        ? assignment_for_node(node, payload_node_id)
        : assignment_for_zone(node, topic_zone_id);
    if (assignment && strcmp(assignment->zone_id, topic_zone_id) != 0) {
        mqtt_publish_actuator_status_now(node, topic_zone_id, payload_node_id, idempotency_key, NULL, ACTUATOR_STATUS_FAULT, "ZONE_MISMATCH", "node assignment zone_id does not match command topic");
        set_error(node, "actuator node zone mismatch");
        return;
    }
    if (!assignment || assignment->irrigation_line == 0 || assignment->irrigation_line > node->irrigation_line_count) {
        mqtt_publish_actuator_status_now(node, topic_zone_id, payload_node_id, idempotency_key, NULL, ACTUATOR_STATUS_FAULT, "UNASSIGNED_LINE", "target has no irrigation line mapping");
        set_error(node, "target missing irrigation line");
        return;
    }

    actuator_line_run_t *run = run_for_line(node, assignment->irrigation_line);
    if (!run) {
        set_error(node, "invalid irrigation line");
        return;
    }

    if (strcmp(command, "stop_watering") == 0) {
        printf("[actuator] command=stop zone=%s node=%s id=%s\n", topic_zone_id, assignment->node_id, idempotency_key);
        if (run->running) {
            actuator_stop_with_status(node, run, assignment->irrigation_line, ACTUATOR_STATUS_STOPPED, NULL, NULL);
        } else {
            mqtt_publish_actuator_status_now(node, topic_zone_id, assignment->node_id, idempotency_key, NULL, ACTUATOR_STATUS_STOPPED, NULL, NULL);
        }
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

    printf("[actuator] command=%s zone=%s node=%s id=%s runtime=%d running=%d\n",
           command,
           topic_zone_id,
           assignment->node_id,
           idempotency_key,
           runtime_seconds,
           (int)run->running);

    // Compare the full int, not a uint16_t cast of it -- casting first would
    // silently drop the high bits (e.g. runtime_seconds=65566 truncates to
    // 30, which could compare as "under the cap" even though the real value
    // is over 18 hours), letting a crafted or buggy runtime_seconds bypass
    // this safety clamp entirely while still being stored and scheduled at
    // its full, unclamped size below.
    if (node->config->max_pulse_runtime_sec > 0 && runtime_seconds > (int)node->config->max_pulse_runtime_sec) {
        runtime_seconds = (int)node->config->max_pulse_runtime_sec;
    }

    if (run->running) {
        mqtt_publish_actuator_status_now(node, topic_zone_id, assignment->node_id, idempotency_key, run, ACTUATOR_STATUS_FAULT, "ALREADY_RUNNING", "relay line is already watering");
        set_error(node, "relay line already running");
        return;
    }

    memset(run, 0, sizeof(*run));
    run->running = true;
    snprintf(run->zone_id, sizeof(run->zone_id), "%s", topic_zone_id);
    snprintf(run->node_id, sizeof(run->node_id), "%s", assignment->node_id);
    snprintf(run->idempotency_key, sizeof(run->idempotency_key), "%s", idempotency_key);
    run->started_at_ms = to_ms_since_boot(get_absolute_time());
    run->runtime_seconds = (uint32_t)runtime_seconds;
    run->hard_deadline = make_timeout_time_ms((uint32_t)runtime_seconds * 1000u);

    // Independent hardware backstop for hard_deadline — see
    // actuator_hw_cutoff_callback. Snapshot the GPIO/level now so the ISR
    // never has to touch node->config.
    run->cutoff_gpio = line_gpio_for_index(node, (size_t)(assignment->irrigation_line - 1u));
    run->cutoff_off_level = !node->config->actuator_relay_active_high;
    run->hardware_cutoff_fired = false;
    run->cutoff_alarm_id = add_alarm_in_ms(
        (uint32_t)runtime_seconds * 1000u, actuator_hw_cutoff_callback, run, true);
    if (run->cutoff_alarm_id < 0) {
        printf("[actuator] WARNING: hardware cutoff alarm scheduling failed line=%u — software deadline check is the only cutoff for this run\n",
               (unsigned)assignment->irrigation_line);
        stdio_flush();
    }

    mqtt_publish_actuator_status_now(node, topic_zone_id, run->node_id, idempotency_key, run, ACTUATOR_STATUS_ACKNOWLEDGED, NULL, NULL);
    actuator_set_line_output(node, assignment->irrigation_line, true);
    mqtt_publish_actuator_status_now(node, topic_zone_id, run->node_id, idempotency_key, run, ACTUATOR_STATUS_RUNNING, NULL, NULL);

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
    char actuator_config_topic[MQTT_RX_TOPIC_MAX];
    char topic_zone_id[VG_MAX_ZONE_ID_LEN] = {0};
    topic_actuator_system_config(actuator_config_topic, sizeof(actuator_config_topic));

    if (actuator_command_topic_match(g_runtime.incoming_topic, topic_zone_id, sizeof(topic_zone_id))) {
        handle_actuator_command_message(node, topic_zone_id, g_runtime.incoming_payload);
    } else if (topic_equals(g_runtime.incoming_topic, actuator_config_topic)) {
        handle_actuator_config_message(node, g_runtime.incoming_payload);
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
    char actuator_config_topic[MQTT_RX_TOPIC_MAX];
    topic_actuator_system_config(actuator_config_topic, sizeof(actuator_config_topic));
    err_t actuator_config_err = mqtt_subscribe_locked(g_runtime.client, actuator_config_topic, 0, mqtt_request_cb, node);
    printf("[mqtt] subscribe config topic=%s err=%d\n", actuator_config_topic, (int)actuator_config_err);
    subscribe_assigned_zone_topics(node);
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
        mqtt_set_inpub_callback(g_runtime.client, mqtt_incoming_publish_cb, mqtt_incoming_data_cb, node);
        subscribe_topics(node);
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
    node->irrigation_line_count = 1u;
    snprintf(node->last_error, sizeof(node->last_error), "none");
    memset(&g_runtime, 0, sizeof(g_runtime));
    g_runtime.node = node;
    g_runtime.next_reconnect_at = get_absolute_time();
    g_runtime.discovery_next_attempt_at = get_absolute_time();

    for (size_t i = 0; i < VG_MAX_IRRIGATION_LINES; ++i) {
        uint8_t gpio = line_gpio_for_index(node, i);
        gpio_init(gpio);
        gpio_set_dir(gpio, GPIO_OUT);
        actuator_set_line_output(node, (uint8_t)(i + 1u), false);
    }
    printf("[actuator] initialized first_line_gp=%u active_high=%d max_lines=%u\n",
           (unsigned)line_gpio_for_index(node, 0),
           (int)config->actuator_relay_active_high,
           (unsigned)VG_MAX_IRRIGATION_LINES);
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
    snprintf(g_runtime.client_id, sizeof(g_runtime.client_id), "actuator-%s", node->config->node_id);
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
        printf("[mqtt] connect initiated - waiting for callback\n");
        g_runtime.next_reconnect_at = make_timeout_time_ms(15000);
    }
}

void mqtt_node_poll(mqtt_node_t *node) {
    mqtt_ensure_connected(g_runtime.node);

    if (g_runtime.pending_diagnostic_event && g_runtime.client && mqtt_client_is_connected(g_runtime.client)) {
        if (publish_node_diagnostic_event(node, g_runtime.pending_diagnostic_event_code, g_runtime.pending_diagnostic_event_detail)) {
            g_runtime.pending_diagnostic_event = false;
        }
    }

    for (size_t i = 0; i < VG_MAX_IRRIGATION_LINES; ++i) {
        actuator_line_run_t *run = &node->runs[i];
        if (!run->running) {
            continue;
        }

        if (absolute_time_diff_us(get_absolute_time(), run->hard_deadline) <= 0) {
            actuator_stop_with_status(node, run, (uint8_t)(i + 1u), ACTUATOR_STATUS_COMPLETED, NULL, NULL);
        }
    }
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
        // A discovery result is not trusted until MQTT authentication has
        // succeeded. Revert an in-flight candidate before rebuilding the
        // client so a Wi-Fi reconnect cannot accidentally make it sticky.
        snprintf(node->config->mqtt_host, sizeof(node->config->mqtt_host), "%s", g_runtime.broker_fallback_host);
        node->config->mqtt_port = g_runtime.broker_fallback_port;
    }

    g_runtime.client = NULL;
    g_runtime.connected = false;
    g_runtime.discovery_in_progress = false;
    g_runtime.discovery_resolved = false;
    g_runtime.discovery_pcb = NULL;
    g_runtime.broker_candidate_pending = false;
    g_runtime.discovered_mqtt_host[0] = '\0';
    g_runtime.discovered_mqtt_port = 0;
    g_runtime.incoming_payload_len = 0;
    g_runtime.incoming_topic[0] = '\0';
    g_runtime.incoming_payload[0] = '\0';
    g_runtime.next_reconnect_at = get_absolute_time();
    g_runtime.discovery_next_attempt_at = get_absolute_time();
    g_runtime.discovery_deadline = get_absolute_time();

    // Assignments, active runs, hardware cutoff alarms, and any queued
    // outage diagnostic stay on their existing state and survive reconnect.
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

bool mqtt_node_take_reconnect_request(mqtt_node_t *node) {
    bool requested = node->config_changed_requires_reconnect;
    node->config_changed_requires_reconnect = false;
    return requested;
}
