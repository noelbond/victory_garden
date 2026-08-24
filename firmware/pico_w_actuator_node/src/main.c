#include <stdio.h>

#include "config.h"
#include "hardware/watchdog.h"
#include "mqtt_node.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "time_sync.h"
#include "wifi.h"

static const uint32_t VG_WIFI_STABILIZE_MS = 5000u;
static const uint32_t VG_WIFI_IP_WAIT_MS = 30000u;
static const size_t VG_PROVISION_LINE_MAX = 2048u;
static const uint32_t VG_PROVISIONING_ANNOUNCE_MS = 2000u;
static const uint32_t VG_CONFIG_REVIEW_TIMEOUT_MS = 5u * 60u * 1000u;
static const uint32_t VG_USB_ENUMERATION_GRACE_MS = 3000u;
// RP2040 hardware watchdog max is ~8388ms (RP2040-E1); stay comfortably under it.
static const uint32_t VG_WATCHDOG_TIMEOUT_MS = 8000u;
// wifi_connect_with_retry() pets the watchdog through every retry, so a Wi-Fi
// outage this long can't be caught by the watchdog on its own — it'll retry
// forever without ever forcing a clean reinit of a possibly-wedged cyw43
// radio. Bound it: after this long of unbroken failure, force a reboot.
static const uint32_t VG_WIFI_RETRY_REBOOT_MS = 5u * 60u * 1000u;
#define VG_SKIP_REVIEW_ONCE_MAGIC 0x56475201u

static void print_json_string(const char *value) {
    putchar('"');
    for (const unsigned char *cursor = (const unsigned char *)(value ? value : ""); *cursor; ++cursor) {
        if (*cursor == '"' || *cursor == '\\') {
            putchar('\\');
            putchar((int)*cursor);
        } else {
            putchar(*cursor < 0x20 ? '_' : (int)*cursor);
        }
    }
    putchar('"');
}

static void provisioning_announce(const node_config_t *config, bool requires_provisioning) {
    printf("VG_READY {\"role\":\"actuator\",\"node_id\":");
    print_json_string(config->node_id);
    printf(",\"zone_id\":");
    print_json_string(config->zone_id);
    printf(",\"requires_provisioning\":%s,\"wifi_ssid\":", requires_provisioning ? "true" : "false");
    print_json_string(config->wifi_ssid);
    printf(",\"mqtt_host\":");
    print_json_string(config->mqtt_host);
    printf(",\"mqtt_port\":%u}\n", (unsigned)config->mqtt_port);
    stdio_flush();
}

static void wait_for_usb_provisioning(node_config_t *config) {
    if (watchdog_hw->scratch[2] == VG_SKIP_REVIEW_ONCE_MAGIC) {
        watchdog_hw->scratch[2] = 0;
        return;
    }
    bool requires_provisioning = node_config_requires_provisioning(config);
    if (!requires_provisioning) {
        absolute_time_t usb_deadline = make_timeout_time_ms(VG_USB_ENUMERATION_GRACE_MS);
        while (!stdio_usb_connected() && absolute_time_diff_us(get_absolute_time(), usb_deadline) > 0) {
            sleep_ms(25);
        }
        if (!stdio_usb_connected()) {
            return;
        }
    }

    char line[VG_PROVISION_LINE_MAX];
    size_t line_len = 0;
    absolute_time_t next_announce_at = get_absolute_time();
    absolute_time_t review_deadline = make_timeout_time_ms(VG_CONFIG_REVIEW_TIMEOUT_MS);
    char error[128] = {0};

    while (true) {
        if (!requires_provisioning && absolute_time_diff_us(get_absolute_time(), review_deadline) <= 0) {
            printf("VG_PRESERVE_TIMEOUT {\"preserved\":true,\"reason\":\"no decision received\"}\n");
            stdio_flush();
            return;
        }
        if (absolute_time_diff_us(get_absolute_time(), next_announce_at) <= 0) {
            provisioning_announce(config, requires_provisioning);
            next_announce_at = make_timeout_time_ms(VG_PROVISIONING_ANNOUNCE_MS);
        }

        int ch = getchar_timeout_us(10 * 1000);
        if (ch == PICO_ERROR_TIMEOUT) {
            tight_loop_contents();
            continue;
        }

        if (ch == '\r') {
            continue;
        }

        if (ch != '\n' && line_len + 1 < sizeof(line)) {
            line[line_len++] = (char)ch;
            continue;
        }

        line[line_len] = '\0';
        line_len = 0;

        if (strcmp(line, "VG_PRESERVE") == 0) {
            if (requires_provisioning) {
                printf("VG_PROVISION_ERROR no valid configuration to preserve\n");
                stdio_flush();
                continue;
            }
            printf("VG_PRESERVE_OK {\"preserved\":true}\n");
            stdio_flush();
            return;
        }

        if (strncmp(line, "VG_PROVISION ", 13) != 0) {
            if (strcmp(line, "VG_IDENTIFY") == 0) {
                provisioning_announce(config, requires_provisioning);
            }
            continue;
        }

        if (!node_config_apply_provision_json(config, line + 13, error, sizeof(error))) {
            printf("VG_PROVISION_ERROR %s\n", error);
            stdio_flush();
            continue;
        }

        if (!node_config_save(config, error, sizeof(error))) {
            printf("VG_PROVISION_ERROR %s\n", error);
            stdio_flush();
            continue;
        }

        printf("VG_PROVISION_OK {\"node_id\":\"%s\",\"zone_id\":\"%s\",\"rebooting\":true}\n",
            config->node_id,
            config->zone_id);
        stdio_flush();
        sleep_ms(200);
        watchdog_hw->scratch[2] = VG_SKIP_REVIEW_ONCE_MAGIC;
        watchdog_reboot(0, 0, 100);
    }
}

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
    absolute_time_t retry_reboot_deadline = make_timeout_time_ms(VG_WIFI_RETRY_REBOOT_MS);
    while (!wifi_init_and_connect(config, error, error_size)) {
        printf("[wifi] failed: %s - retry in 5s\n", error);
        stdio_flush();
        if (absolute_time_diff_us(get_absolute_time(), retry_reboot_deadline) <= 0) {
            // Wi-Fi has been unreachable for VG_WIFI_RETRY_REBOOT_MS straight.
            // Stop petting the watchdog and force a full reboot instead of
            // retrying forever — a clean boot re-inits the cyw43 driver from
            // scratch, which can recover a wedged radio that a plain retry
            // can't.
            printf("[wifi] unreachable for %us straight, forcing reboot\n",
                   (unsigned)(VG_WIFI_RETRY_REBOOT_MS / 1000u));
            stdio_flush();
            watchdog_reboot(0, 0, 100);
            while (true) {
                tight_loop_contents();
            }
        }
        watchdog_update();
        sleep_ms(5000);
        watchdog_update();
    }
    printf("[wifi] connected\n");
    stdio_flush();
    watchdog_update();
    return true;
}

int main(void) {
    stdio_init_all();
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    sleep_ms(3000);
    printf("[main] boot\n");
    stdio_flush();

    node_config_t config;
    mqtt_node_t node;
    char wifi_error[128] = {0};

    node_config_load(&config);
    wait_for_usb_provisioning(&config);

    // Arm the watchdog now that the interactive USB provisioning wait is
    // behind us. From here on, a hang anywhere in the operational loop
    // forces a reboot instead of leaving the relay/network stack wedged.
    watchdog_enable(VG_WATCHDOG_TIMEOUT_MS, true);

    // Force every relay to its safe OFF level before touching Wi-Fi/MQTT,
    // so a relay is never left floating while the board is offline —
    // including the time it takes to reconnect after any reboot.
    actuator_relays_init_safe(&config);

    printf("[main] config: node=%s zone=%s broker=%s:%d\n",
        config.node_id, config.zone_id, config.mqtt_host, config.mqtt_port);
    printf("[main] actuator: relay=GP%u active_high=%d max_runtime=%us\n",
        (unsigned)config.actuator_relay_gpio,
        (int)config.actuator_relay_active_high,
        (unsigned)config.max_pulse_runtime_sec);
    stdio_flush();

    wifi_connect_with_retry(&config, wifi_error, sizeof(wifi_error));
    time_sync_init();
    mqtt_node_init(&node, &config);

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
            // The old TCP session belongs to the lost Wi-Fi link. Do not
            // rely on lwIP noticing that stale socket on its own after the
            // station reconnects; rebuild MQTT and all subscriptions now.
            (void)mqtt_node_take_reconnect_request(&node);
            mqtt_node_disconnect(&node);
            wifi_reconnect_allowed_at = make_timeout_time_ms(VG_WIFI_STABILIZE_MS);
            wifi_ip_wait_started_at = get_absolute_time();
            canary_published = false;
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
            canary_published = false;
        }

        if (mqtt_node_is_connected(&node) && !canary_published) {
            if (mqtt_node_publish_canary(&node)) {
                canary_published = true;
            } else {
                printf("[mqtt] canary failed err=%s\n", node.last_error);
                stdio_flush();
            }
        }

        watchdog_update();
        cyw43_arch_wait_for_work_until(make_timeout_time_ms(100));
    }
}
