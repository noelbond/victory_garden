#include <stdio.h>

#include "config.h"
#include "mqtt_node.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "sensors.h"
#include "time_sync.h"
#include "wifi.h"

static const uint32_t VG_PUBLISH_RETRY_MS = 5000u;
static const uint32_t VG_WIFI_STABILIZE_MS = 5000u;
static const uint32_t VG_WIFI_IP_WAIT_MS = 30000u;

static bool wifi_link_needs_reconnect(int link_status, absolute_time_t reconnect_allowed_at,
                                      absolute_time_t ip_wait_started_at) {
    if (wifi_is_connected()) {
        return false;
    }

    if (link_status == CYW43_LINK_DOWN || link_status == CYW43_LINK_FAIL ||
        link_status == CYW43_LINK_NONET || link_status == CYW43_LINK_BADAUTH) {
        return absolute_time_diff_us(get_absolute_time(), reconnect_allowed_at) <= 0;
    }

    if (link_status == CYW43_LINK_JOIN || link_status == CYW43_LINK_NOIP) {
        return absolute_time_diff_us(get_absolute_time(),
                                     delayed_by_ms(ip_wait_started_at, VG_WIFI_IP_WAIT_MS)) <= 0;
    }

    return false;
}

static bool wifi_connect_with_retry(const node_config_t *config, char *error, size_t error_size) {
    printf("[wifi] connecting ssid=%s\n", config->wifi_ssid);
    while (!wifi_init_and_connect(config, error, error_size)) {
        printf("[wifi] failed: %s — retry in 5s\n", error);
        sleep_ms(5000);
    }
    printf("[wifi] connected\n");
    return true;
}

int main(void) {
    stdio_init_all();
    sleep_ms(3000);
    printf("[main] boot\n");
    stdio_flush();

    node_config_t config;
    mqtt_node_t node;
    sensor_snapshot_t snapshot;
    char wifi_error[128] = {0};

    node_config_load(&config);
    printf("[main] config: node=%s zone=%s broker=%s:%d\n",
        config.node_id, config.zone_id, config.mqtt_host, config.mqtt_port);
    printf("[main] wifi: ssid=%s password_len=%u\n",
        config.wifi_ssid, (unsigned)strlen(config.wifi_password));

    sensors_init(&config);
    wifi_connect_with_retry(&config, wifi_error, sizeof(wifi_error));
    time_sync_init();
    mqtt_node_init(&node, &config);
    printf("[main] entering loop\n");

    absolute_time_t next_publish_at = get_absolute_time();
    absolute_time_t next_publish_attempt_at = get_absolute_time();
    absolute_time_t next_heartbeat_at = get_absolute_time();
    absolute_time_t wifi_reconnect_allowed_at = make_timeout_time_ms(VG_WIFI_STABILIZE_MS);
    absolute_time_t wifi_ip_wait_started_at = get_absolute_time();
    bool canary_published = false;
    bool mqtt_was_connected = false;

    while (true) {
        wifi_poll();
        time_sync_poll();

        int link_status = wifi_link_status();
        if (link_status == CYW43_LINK_UP) {
            wifi_ip_wait_started_at = get_absolute_time();
        }

        if (wifi_link_needs_reconnect(link_status, wifi_reconnect_allowed_at, wifi_ip_wait_started_at)) {
            printf("[wifi] reconnecting link=%d\n", link_status);
            wifi_deinit();
            wifi_connect_with_retry(&config, wifi_error, sizeof(wifi_error));
            mqtt_node_take_reconnect_request(&node);
            next_publish_at = get_absolute_time();
            next_publish_attempt_at = get_absolute_time();
            wifi_reconnect_allowed_at = make_timeout_time_ms(VG_WIFI_STABILIZE_MS);
            wifi_ip_wait_started_at = get_absolute_time();
            canary_published = false;
        }

        mqtt_node_poll(&node);

        bool mqtt_now = mqtt_node_is_connected(&node);
        if (mqtt_now && !mqtt_was_connected) {
            printf("[mqtt] connected\n");
        } else if (!mqtt_now && mqtt_was_connected) {
            printf("[mqtt] disconnected err=%s\n", node.last_error);
        }
        mqtt_was_connected = mqtt_now;

        if (mqtt_node_take_reconnect_request(&node)) {
            sensors_init(&config);
            next_publish_at = get_absolute_time();
            next_publish_attempt_at = get_absolute_time();
            canary_published = false;
        }

        if (mqtt_node_is_connected(&node) && !canary_published) {
            printf("[mqtt] publishing canary\n");
            if (mqtt_node_publish_canary(&node)) {
                printf("[mqtt] canary ok\n");
                canary_published = true;
            } else {
                printf("[mqtt] canary failed err=%s\n", node.last_error);
            }
        }

        bool publish_due = absolute_time_diff_us(get_absolute_time(), next_publish_at) <= 0;
        bool publish_allowed = absolute_time_diff_us(get_absolute_time(), next_publish_attempt_at) <= 0;
        bool publish_requested = mqtt_node_take_publish_request(&node);
        if ((publish_due || publish_requested) && publish_allowed && mqtt_node_is_connected(&node)) {
            const char *reason = publish_requested ? "request_reading" : "interval";
            printf("[main] publish reason=%s\n", reason);
            if (sensors_read(&config, &snapshot)) {
                if (mqtt_node_publish_state(&node, &snapshot, reason)) {
                    printf("[main] publish ok\n");
                    next_publish_at = make_timeout_time_ms(config.publish_interval_ms);
                    next_publish_attempt_at = get_absolute_time();
                } else {
                    printf("[main] publish failed err=%s\n", node.last_error);
                    if (publish_requested) {
                        node.publish_requested = true;
                    }
                    next_publish_attempt_at = make_timeout_time_ms(VG_PUBLISH_RETRY_MS);
                }
            } else {
                printf("[main] sensors_read failed\n");
            }
        }

        if (absolute_time_diff_us(get_absolute_time(), next_heartbeat_at) <= 0) {
            char ip_buf[32] = "none";
            if (!wifi_ip_string(ip_buf, sizeof(ip_buf))) {
                snprintf(ip_buf, sizeof(ip_buf), "none");
            }
            printf("[heartbeat] uptime=%lums ssid=%s password_len=%u wifi=%d link=%d mqtt=%d err=%s\n",
                (unsigned long)to_ms_since_boot(get_absolute_time()),
                config.wifi_ssid,
                (unsigned)strlen(config.wifi_password),
                (int)wifi_is_connected(),
                link_status,
                (int)mqtt_node_is_connected(&node),
                node.last_error);
            printf("[heartbeat] ip=%s rssi=%ld time_synced=%d\n", ip_buf, (long)wifi_rssi(), (int)time_sync_ready());
            stdio_flush();
            next_heartbeat_at = make_timeout_time_ms(2000);
        }

        cyw43_arch_wait_for_work_until(make_timeout_time_ms(100));
    }
}
