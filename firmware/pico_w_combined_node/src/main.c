#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "config.h"
#include "hardware/watchdog.h"
#include "mqtt_node.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "sensors.h"
#include "sht40.h"
#include "time_sync.h"
#include "wifi.h"

static const uint32_t VG_WIFI_STABILIZE_MS = 5000u;
static const uint32_t VG_WIFI_IP_WAIT_MS = 30000u;
static const uint32_t VG_PROVISIONING_ANNOUNCE_MS = 2000u;
static const uint32_t VG_CONFIG_REVIEW_TIMEOUT_MS = 5u * 60u * 1000u;
static const uint32_t VG_USB_ENUMERATION_GRACE_MS = 3000u;
static const size_t VG_PROVISION_LINE_MAX = 2048u;
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
    printf("VG_READY {\"role\":\"combined\",\"node_id\":");
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

        printf("VG_PROVISION_OK {\"node_id\":\"%s\",\"zone_id\":\"%s\",\"channels\":[\"%s\",\"%s\",\"%s\",\"%s\"],\"rebooting\":true}\n",
            config->node_id,
            config->zone_id,
            config->channel_node_id[0],
            config->channel_node_id[1],
            config->channel_node_id[2],
            config->channel_node_id[3]);
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
            // can't, and it also produces the boot-forced sensor reading
            // once reconnected so a long outage shows up in history instead
            // of just silently persisting.
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

static uint32_t local_seconds_today(uint32_t epoch_sec, int8_t utc_offset_hours) {
    int64_t local_epoch = (int64_t)epoch_sec + ((int64_t)utc_offset_hours * 3600ll);
    int32_t seconds_today = (int32_t)(local_epoch % 86400ll);
    return (uint32_t)(seconds_today < 0 ? seconds_today + 86400 : seconds_today);
}

static bool is_active_window(uint32_t epoch_sec, int8_t utc_offset_hours) {
    const uint32_t hour = local_seconds_today(epoch_sec, utc_offset_hours) / 3600u;
    return hour >= VG_DAY_START_HOUR && hour < VG_DAY_END_HOUR;
}

// Runs one temperature/humidity + (optionally) soil-moisture reading pass and
// publishes state for every ADS1115 channel. Called from the persistent main
// loop on a due timer or an explicit request_reading command — this firmware
// never sleeps the CPU between reads (see README), so there is no wake-cycle
// bookkeeping like the split sensor board has.
static void run_sensor_cycle(mqtt_node_t *node, node_config_t *config, bool read_soil, const char *reason, uint32_t wake_count) {
    watchdog_update();
    if (VG_ENABLE_I2C_DIAGNOSTIC_SCAN) {
        sht40_scan_bus(config);
    }

    float air_temperature_c = 0.0f;
    float humidity_percent = 0.0f;
    bool environment_valid = sht40_read(config, &air_temperature_c, &humidity_percent);
    bool sht40_present = true;
    if (!environment_valid) {
        sht40_present = sht40_probe(config);
        snprintf(
            node->last_error,
            sizeof(node->last_error),
            "sht40 read failed; 0x44 %s",
            sht40_present ? "present" : "missing"
        );
        printf("[main] %s; continuing with degraded publish\n", node->last_error);
        stdio_flush();
    }

    if (read_soil) {
        sensors_init(config);
    }
    printf("[cycle] sensors temp_c=%.2f humidity=%.2f soil=%s reason=%s\n",
        (double)air_temperature_c,
        (double)humidity_percent,
        read_soil ? "yes" : "no",
        reason);
    stdio_flush();

    uint8_t successful_soil_reads = 0;
    for (uint8_t ch = 0; ch < VG_ADS1115_CHANNEL_COUNT; ++ch) {
        sensor_snapshot_t ch_snapshot = {0};
        ch_snapshot.air_temperature_c = air_temperature_c;
        ch_snapshot.humidity_percent = humidity_percent;
        ch_snapshot.environment_valid = environment_valid;
        ch_snapshot.healthy = environment_valid;
        if (read_soil) {
            ch_snapshot.soil_moisture_read = sensors_read(config, ch, &ch_snapshot);
            if (ch_snapshot.soil_moisture_read) {
                successful_soil_reads++;
            } else {
                printf("[main] channel %u soil read failed, publishing environment only\n", (unsigned)ch);
                stdio_flush();
                ch_snapshot.healthy = false;
            }
        }

        if (!environment_valid) {
            snprintf(
                node->last_error,
                sizeof(node->last_error),
                "sht40 read failed; 0x44 %s",
                sht40_present ? "present" : "missing"
            );
        } else if (read_soil && !ch_snapshot.soil_moisture_read) {
            snprintf(node->last_error, sizeof(node->last_error), "channel %u soil read failed", (unsigned)ch);
        } else if (read_soil && !ch_snapshot.healthy) {
            snprintf(node->last_error, sizeof(node->last_error), "channel %u raw outside calibration", (unsigned)ch);
        } else {
            snprintf(node->last_error, sizeof(node->last_error), "%s", "none");
        }

        printf("[cycle] publishing channel %u node=%s reason=%s soil_read=%s moisture_raw=%u moisture_percent=%d\n",
            (unsigned)ch,
            config->channel_node_id[ch],
            reason,
            ch_snapshot.soil_moisture_read ? "true" : "false",
            ch_snapshot.moisture_raw,
            ch_snapshot.moisture_percent);
        stdio_flush();

        bool published = mqtt_node_publish_state(node, &ch_snapshot, reason, wake_count, config->channel_node_id[ch]);
        if (!published) {
            mqtt_node_poll(node);
            published = mqtt_node_publish_state(node, &ch_snapshot, reason, wake_count, config->channel_node_id[ch]);
        }
        if (!published) {
            printf("[main] channel %u publish failed err=%s\n", (unsigned)ch, node->last_error);
            stdio_flush();
        }
    }

    if (read_soil && successful_soil_reads == 0) {
        printf("[main] all soil channel reads failed; environment readings were still published\n");
        stdio_flush();
    }
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

    printf("[main] config: node=%s zone=%s broker=%s:%d utc_offset_hours=%d\n",
        config.node_id, config.zone_id, config.mqtt_host, config.mqtt_port, (int)config.utc_offset_hours);
    printf("[main] actuator: relay=GP%u active_high=%d max_pulse_runtime=%us\n",
        (unsigned)config.actuator_relay_gpio,
        (int)config.actuator_relay_active_high,
        (unsigned)config.max_pulse_runtime_sec);
    printf("[main] ads1115: sda=GP%u scl=GP%u addr=0x%02X channels=%u\n",
        (unsigned)config.ads1115_i2c_sda_gpio,
        (unsigned)config.ads1115_i2c_scl_gpio,
        (unsigned)config.ads1115_i2c_address,
        (unsigned)VG_ADS1115_CHANNEL_COUNT);
    for (uint8_t ch = 0; ch < VG_ADS1115_CHANNEL_COUNT; ++ch) {
        printf("[main] ads1115 ch%u: node=%s dry=%u wet=%u\n",
            (unsigned)ch,
            config.channel_node_id[ch],
            (unsigned)config.channel_moisture_raw_dry[ch],
            (unsigned)config.channel_moisture_raw_wet[ch]);
    }
    stdio_flush();

    wifi_connect_with_retry(&config, wifi_error, sizeof(wifi_error));
    time_sync_init();
    mqtt_node_init(&node, &config);

    absolute_time_t wifi_reconnect_allowed_at = make_timeout_time_ms(VG_WIFI_STABILIZE_MS);
    absolute_time_t wifi_ip_wait_started_at = get_absolute_time();
    bool canary_published = false;
    bool mqtt_was_connected = false;

    const uint32_t temp_interval_sec = VG_TEMP_INTERVAL_MINUTES * 60u;
    const uint32_t soil_interval_sec = VG_SOIL_INTERVAL_MINUTES * 60u;
    uint32_t last_temp_marker = UINT32_MAX;
    uint32_t last_soil_marker = UINT32_MAX;
    uint32_t wake_count = 0;
    bool boot_reading_done = false;

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
            // A node-config message changed this board's own zone_id. The
            // sensor's zone-scoped command/command_ack topics were
            // subscribed under the old zone_id, so force a clean MQTT
            // disconnect/reconnect to resubscribe under the new one —
            // mqtt_ensure_connected() will re-establish the connection and
            // subscribe_topics() picks up the current config->zone_id.
            printf("[main] zone changed, forcing mqtt reconnect\n");
            stdio_flush();
            mqtt_node_disconnect(&node);
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

        if (mqtt_node_take_reboot_request(&node)) {
            printf("[main] reboot requested\n");
            stdio_flush();
            // watchdog_reboot() schedules a hardware reset delay_ms in the
            // future -- it does NOT halt execution. Falling through to the
            // top of the loop here previously let an already-in-flight
            // command (e.g. request_reading arriving seconds after reboot)
            // run a full extra cycle before the reset actually fired. Halt
            // explicitly instead of returning to the loop.
            watchdog_reboot(0, 0, 100);
            while (true) {
                tight_loop_contents();
            }
        }

        // Interval/active-window scheduling is inherently tied to synced
        // wall-clock time (it lines up with VG_DAY_START_HOUR/VG_DAY_END_HOUR)
        // and stays gated on time_sync_ready() below. The boot-forced and
        // explicit-request readings do NOT wait on it, though: if NTP/DNS is
        // down, gating everything on time sync meant the board would never
        // publish a single reading -- not even in response to a manual
        // Request Reading -- for as long as the outage lasted, with no visible
        // signal anywhere why. run_sensor_cycle()'s publish path already falls
        // back to an unambiguous sentinel timestamp when time isn't synced
        // (Rails substitutes server time for it on ingest), so it's safe to
        // fire without waiting.
        bool publish_requested = mqtt_node_has_publish_request(&node);

        if (!boot_reading_done && mqtt_node_is_connected(&node)) {
            // Take one reading immediately after every boot, regardless of
            // the active window, so a reboot (deliberate or watchdog-forced)
            // visibly confirms the board came back healthy and backfills
            // whatever reading interval was missed during the outage.
            // Gated on mqtt_node_is_connected() (not just time_sync_ready())
            // because time sync can finish before MQTT does — firing before
            // the client is connected would silently fail to publish and
            // permanently waste this one-shot flag for the whole boot.
            boot_reading_done = true;
            ++wake_count;
            run_sensor_cycle(&node, &config, true, "boot", wake_count);
            if (time_sync_ready()) {
                uint32_t epoch_sec = time_sync_epoch_sec();
                last_temp_marker = epoch_sec / temp_interval_sec;
                last_soil_marker = epoch_sec / soil_interval_sec;
            }
            if (publish_requested) {
                mqtt_node_take_publish_request(&node);
                mqtt_node_mark_publish_request_handled(&node);
            }
        } else if (time_sync_ready()) {
            uint32_t epoch_sec = time_sync_epoch_sec();

            if (is_active_window(epoch_sec, config.utc_offset_hours)) {
                uint32_t temp_marker = epoch_sec / temp_interval_sec;
                uint32_t soil_marker = epoch_sec / soil_interval_sec;
                bool temp_due = temp_marker != last_temp_marker;
                bool soil_due = soil_marker != last_soil_marker;

                if (temp_due || soil_due || publish_requested) {
                    bool read_soil = soil_due || publish_requested;
                    const char *reason = publish_requested ? "request_reading" : "interval";
                    ++wake_count;
                    run_sensor_cycle(&node, &config, read_soil, reason, wake_count);
                    last_temp_marker = temp_marker;
                    if (read_soil) {
                        last_soil_marker = soil_marker;
                    }
                    if (publish_requested) {
                        mqtt_node_take_publish_request(&node);
                        mqtt_node_mark_publish_request_handled(&node);
                    }
                }
            } else if (publish_requested) {
                // Honor an explicit request even outside the active window.
                ++wake_count;
                run_sensor_cycle(&node, &config, true, "request_reading", wake_count);
                mqtt_node_take_publish_request(&node);
                mqtt_node_mark_publish_request_handled(&node);
            }
        } else if (publish_requested) {
            // Time isn't synced yet, but honor an explicit manual request
            // anyway rather than leaving the operator with no way to get a
            // reading at all during an NTP/DNS outage.
            ++wake_count;
            run_sensor_cycle(&node, &config, true, "request_reading", wake_count);
            mqtt_node_take_publish_request(&node);
            mqtt_node_mark_publish_request_handled(&node);
        }

        watchdog_update();
        cyw43_arch_wait_for_work_until(make_timeout_time_ms(100));
    }
}
