#include <stdio.h>

#include "config.h"
#include "hardware/watchdog.h"
#include "mqtt_node.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "sensors.h"
#include "time_sync.h"
#include "wifi.h"

static const uint32_t VG_PUBLISH_RETRY_MS = 5000u;
static const uint32_t VG_TIME_SYNC_RETRY_MS = 1000u;
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
    stdio_flush();
    while (!wifi_init_and_connect(config, error, error_size)) {
        printf("[wifi] failed: %s - retry in 5s\n", error);
        stdio_flush();
        sleep_ms(5000);
    }
    printf("[wifi] connected\n");
    stdio_flush();
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
    printf("[main] seesaw: sda=GP%u scl=GP%u addr=0x%02X channel=%u dry=%u wet=%u\n",
        (unsigned)config.seesaw_i2c_sda_gpio,
        (unsigned)config.seesaw_i2c_scl_gpio,
        (unsigned)config.seesaw_i2c_address,
        (unsigned)config.seesaw_touch_channel,
        (unsigned)config.moisture_raw_dry,
        (unsigned)config.moisture_raw_wet);
    stdio_flush();
    sensors_init(&config);
    wifi_connect_with_retry(&config, wifi_error, sizeof(wifi_error));
    time_sync_init();
    mqtt_node_init(&node, &config);

    absolute_time_t next_publish_at = get_absolute_time();
    absolute_time_t next_publish_attempt_at = get_absolute_time();
    absolute_time_t wifi_reconnect_allowed_at = make_timeout_time_ms(VG_WIFI_STABILIZE_MS);
    absolute_time_t wifi_ip_wait_started_at = get_absolute_time();
    bool canary_published = false;
    bool initial_synced_publish_pending = true;
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
            initial_synced_publish_pending = true;
        }

        mqtt_node_poll(&node);

        bool mqtt_now = mqtt_node_is_connected(&node);
        if (mqtt_now && !mqtt_was_connected) {
            printf("[mqtt] connected\n");
            stdio_flush();
        } else if (!mqtt_now && mqtt_was_connected) {
            printf("[mqtt] disconnected err=%s\n", node.last_error);
            stdio_flush();
        }
        mqtt_was_connected = mqtt_now;

        if (mqtt_node_take_reconnect_request(&node)) {
            sensors_init(&config);
            next_publish_at = get_absolute_time();
            next_publish_attempt_at = get_absolute_time();
            canary_published = false;
            initial_synced_publish_pending = true;
        }

        if (mqtt_node_take_reboot_request(&node)) {
            printf("[main] reboot requested\n");
            stdio_flush();
            sleep_ms(100);
            watchdog_reboot(0, 0, 100);
        }

        if (mqtt_node_is_connected(&node) && !canary_published) {
            if (mqtt_node_publish_canary(&node)) {
                canary_published = true;
            } else {
                printf("[mqtt] canary failed err=%s\n", node.last_error);
                stdio_flush();
            }
        }

        if (mqtt_node_is_connected(&node) && canary_published && time_sync_ready() && initial_synced_publish_pending) {
            node.publish_requested = true;
            initial_synced_publish_pending = false;
        }

        bool publish_due = absolute_time_diff_us(get_absolute_time(), next_publish_at) <= 0;
        bool publish_allowed = absolute_time_diff_us(get_absolute_time(), next_publish_attempt_at) <= 0;
        bool publish_requested = mqtt_node_has_publish_request(&node);
        bool mqtt_ready = mqtt_node_is_connected(&node);
        bool publish_ready = mqtt_ready && (canary_published || publish_requested);

        if ((publish_due || publish_requested) && publish_allowed && publish_ready) {
            if (publish_requested) {
                mqtt_node_take_publish_request(&node);
            }
            if (!time_sync_ready() && !publish_requested) {
                next_publish_attempt_at = make_timeout_time_ms(VG_TIME_SYNC_RETRY_MS);
                tight_loop_contents();
                continue;
            }

            const char *reason = publish_requested ? "request_reading" : "interval";
            if (sensors_read(&config, &snapshot)) {
                if (mqtt_node_publish_state(&node, &snapshot, reason)) {
                    if (publish_requested) {
                        mqtt_node_mark_publish_request_handled(&node);
                    }
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
                if (publish_requested) {
                    node.publish_requested = true;
                }
                next_publish_at = make_timeout_time_ms(config.publish_interval_ms);
                next_publish_attempt_at = make_timeout_time_ms(VG_PUBLISH_RETRY_MS);
            }
        }

        cyw43_arch_wait_for_work_until(make_timeout_time_ms(100));
    }
}
