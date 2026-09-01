#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "config.h"
#include "hardware/xosc.h"
#include "hardware/watchdog.h"
#if VG_ENABLE_LORA_TRANSPORT
#include "lora_command_runtime.h"
#include "lora_protocol.h"
#include "lora_transport.h"
#endif
#include "mqtt_node.h"
#include "pico/aon_timer.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "sensors.h"
#include "sht40.h"
#include "time_sync.h"
#include "wifi.h"

static const uint32_t VG_WIFI_CONNECT_TIMEOUT_MS = 35000u;
static const uint32_t VG_WIFI_RETRY_DELAY_MS = 1000u;
static const uint32_t VG_TIME_SYNC_TIMEOUT_MS = 30000u;
static const uint32_t VG_MQTT_CONNECT_TIMEOUT_MS = 15000u;
static const uint32_t VG_MQTT_CANARY_TIMEOUT_MS = 5000u;
static const uint32_t VG_MQTT_RETAINED_WINDOW_MS = 5000u;
static const uint32_t VG_IDLE_POLL_MS = 100u;
static const uint32_t VG_PROVISIONING_ANNOUNCE_MS = 2000u;
static const uint32_t VG_CONFIG_REVIEW_TIMEOUT_MS = 5u * 60u * 1000u;
static const uint32_t VG_USB_ENUMERATION_GRACE_MS = 3000u;
static const uint32_t VG_TIME_SYNC_LOG_INTERVAL_MS = 5000u;
static const uint32_t VG_MQTT_LOG_INTERVAL_MS = 5000u;
static const uint32_t VG_CANARY_LOG_INTERVAL_MS = 2000u;
static const uint32_t VG_RETAINED_LOG_INTERVAL_MS = 2000u;
static const uint32_t VG_DRAIN_LOG_INTERVAL_MS = 2000u;
#if VG_ENABLE_LORA_TRANSPORT
#define VG_LORA_RECENT_COMMAND_COUNT 8u
#endif
static const size_t VG_PROVISION_LINE_MAX = 2048u;
// RP2040 hardware watchdog max is ~8388ms (RP2040-E1); stay comfortably under it.
static const uint32_t VG_WATCHDOG_TIMEOUT_MS = 8000u;

#define VG_WAKE_COUNT_MAGIC 0x56474301u
#define VG_SKIP_REVIEW_ONCE_MAGIC 0x56475201u

static volatile bool g_sleep_alarm_fired = false;
static bool g_aon_timer_seeded = false;

static void sleep_alarm_handler(void) {
    g_sleep_alarm_fired = true;
}

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
    printf("VG_READY {\"role\":\"sensor\",\"node_id\":");
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

static uint32_t init_wake_count(void) {
    if (watchdog_hw->scratch[1] != VG_WAKE_COUNT_MAGIC) {
        watchdog_hw->scratch[1] = VG_WAKE_COUNT_MAGIC;
        watchdog_hw->scratch[0] = 0;
    }

    return ++watchdog_hw->scratch[0];
}

static void wifi_leave_station(void) {
    cyw43_arch_lwip_begin();
    cyw43_wifi_leave(&cyw43_state, CYW43_ITF_STA);
    cyw43_arch_lwip_end();
}

static void cleanup_cycle(mqtt_node_t *node) {
    mqtt_node_disconnect(node);
    time_sync_deinit();
    if (wifi_is_initialized()) {
        wifi_leave_station();
    }
}

static bool wifi_connect_with_timeout(const node_config_t *config, char *error, size_t error_size, uint32_t timeout_ms) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);

    printf("[wifi] connecting ssid=%s\n", config->wifi_ssid);
    stdio_flush();

    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        bool connected = wifi_init_and_connect(config, error, error_size);
        watchdog_update();
        if (connected) {
            printf("[wifi] connected\n");
            stdio_flush();
            return true;
        }

        printf("[wifi] failed: %s\n", error);
        stdio_flush();

        if (absolute_time_diff_us(get_absolute_time(), deadline) <= 0) {
            break;
        }

        sleep_ms(VG_WIFI_RETRY_DELAY_MS);
        watchdog_update();
    }

    return false;
}

static bool wait_for_time_sync(uint32_t timeout_ms) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    absolute_time_t next_log_at = get_absolute_time();

    printf("[time] waiting for NTP sync timeout=%lums\n", (unsigned long)timeout_ms);
    stdio_flush();
    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        time_sync_poll();
        if (time_sync_ready()) {
            printf("[time] sync ready epoch=%lu\n", (unsigned long)time_sync_epoch_sec());
            stdio_flush();
            return true;
        }

        if (absolute_time_diff_us(get_absolute_time(), next_log_at) <= 0) {
            printf("[time] still waiting for NTP sync\n");
            stdio_flush();
            next_log_at = make_timeout_time_ms(VG_TIME_SYNC_LOG_INTERVAL_MS);
        }

        watchdog_update();
        sleep_ms(VG_IDLE_POLL_MS);
    }

    printf("[time] sync timed out after %lums\n", (unsigned long)timeout_ms);
    stdio_flush();
    return false;
}

static bool wait_for_mqtt_connection(mqtt_node_t *node, uint32_t timeout_ms) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    absolute_time_t next_log_at = get_absolute_time();

    printf("[mqtt] waiting for broker connect timeout=%lums host=%s port=%d\n",
        (unsigned long)timeout_ms,
        node->config->mqtt_host,
        node->config->mqtt_port);
    stdio_flush();
    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        mqtt_node_poll(node);
        if (mqtt_node_is_connected(node)) {
            printf("[mqtt] broker connected\n");
            stdio_flush();
            return true;
        }

        if (absolute_time_diff_us(get_absolute_time(), next_log_at) <= 0) {
            printf("[mqtt] still waiting err=%s\n", node->last_error);
            stdio_flush();
            next_log_at = make_timeout_time_ms(VG_MQTT_LOG_INTERVAL_MS);
        }

        watchdog_update();
        sleep_ms(VG_IDLE_POLL_MS);
    }

    printf("[mqtt] connect timed out err=%s\n", node->last_error);
    stdio_flush();
    return false;
}

static bool wait_for_canary_publish(mqtt_node_t *node, uint32_t timeout_ms) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    absolute_time_t next_log_at = get_absolute_time();

    printf("[mqtt] publishing canary timeout=%lums\n", (unsigned long)timeout_ms);
    stdio_flush();
    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        mqtt_node_poll(node);
        if (mqtt_node_publish_canary(node)) {
            printf("[mqtt] canary published\n");
            stdio_flush();
            return true;
        }

        if (absolute_time_diff_us(get_absolute_time(), next_log_at) <= 0) {
            printf("[mqtt] canary retry err=%s\n", node->last_error);
            stdio_flush();
            next_log_at = make_timeout_time_ms(VG_CANARY_LOG_INTERVAL_MS);
        }

        watchdog_update();
        sleep_ms(VG_IDLE_POLL_MS);
    }

    printf("[mqtt] canary timed out err=%s\n", node->last_error);
    stdio_flush();
    return false;
}

static void poll_retained_window(mqtt_node_t *node, uint32_t timeout_ms,
                                 bool *reconnect_requested, bool *reboot_requested) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    absolute_time_t next_log_at = get_absolute_time();

    printf("[mqtt] retained command/config window open for %lums\n", (unsigned long)timeout_ms);
    stdio_flush();
    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        mqtt_node_poll(node);

        if (mqtt_node_take_reconnect_request(node)) {
            printf("[mqtt] retained config requested reconnect\n");
            stdio_flush();
            *reconnect_requested = true;
            return;
        }

        if (mqtt_node_take_reboot_request(node)) {
            printf("[mqtt] retained command requested reboot\n");
            stdio_flush();
            *reboot_requested = true;
            return;
        }

        if (absolute_time_diff_us(get_absolute_time(), next_log_at) <= 0) {
            printf("[mqtt] retained window still open publish_requested=%s\n",
                mqtt_node_has_publish_request(node) ? "true" : "false");
            stdio_flush();
            next_log_at = make_timeout_time_ms(VG_RETAINED_LOG_INTERVAL_MS);
        }

        watchdog_update();
        sleep_ms(VG_IDLE_POLL_MS);
    }

    printf("[mqtt] retained window closed publish_requested=%s\n",
        mqtt_node_has_publish_request(node) ? "true" : "false");
    stdio_flush();
}

static void drain_mqtt_window(mqtt_node_t *node, uint32_t timeout_ms) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    absolute_time_t next_log_at = get_absolute_time();

    printf("[mqtt] draining deferred MQTT work for %lums\n", (unsigned long)timeout_ms);
    stdio_flush();
    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        mqtt_node_poll(node);

        if (absolute_time_diff_us(get_absolute_time(), next_log_at) <= 0) {
            printf("[mqtt] drain in progress\n");
            stdio_flush();
            next_log_at = make_timeout_time_ms(VG_DRAIN_LOG_INTERVAL_MS);
        }

        watchdog_update();
        sleep_ms(VG_IDLE_POLL_MS);
    }

    printf("[mqtt] drain complete\n");
    stdio_flush();
}

static void service_mqtt_window(mqtt_node_t *node, uint32_t timeout_ms) {
    absolute_time_t deadline = make_timeout_time_ms(timeout_ms);
    while (absolute_time_diff_us(get_absolute_time(), deadline) > 0) {
        mqtt_node_poll(node);
        watchdog_update();
        sleep_ms(10);
    }
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

static bool should_read_soil_moisture(uint32_t epoch_sec, int8_t utc_offset_hours) {
    const uint32_t minute = (local_seconds_today(epoch_sec, utc_offset_hours) / 60u) % 60u;
    return minute % VG_SOIL_INTERVAL_MINUTES == 0u;
}

static uint32_t seconds_until_next_wake(uint32_t epoch_sec, int8_t utc_offset_hours) {
    const uint32_t now = local_seconds_today(epoch_sec, utc_offset_hours);
    const uint32_t start = VG_DAY_START_HOUR * 3600u;
    const uint32_t end = VG_DAY_END_HOUR * 3600u;
    const uint32_t interval = VG_TEMP_INTERVAL_MINUTES * 60u;

    if (now < start) {
        return start - now;
    }
    if (now >= end) {
        return (86400u - now) + start;
    }

    const uint32_t next = ((now / interval) + 1u) * interval;
    return next >= end ? (86400u - now) + start : next - now;
}

static uint32_t normalize_sleep_sec(uint32_t sleep_sec) {
    return sleep_sec == 0u ? 1u : sleep_sec;
}

static bool aon_timer_sync_from_epoch(uint32_t epoch_sec) {
    if (epoch_sec == 0u) {
        return false;
    }

    struct timespec ts = {
        .tv_sec = (time_t)epoch_sec,
        .tv_nsec = 0,
    };

    bool ok = g_aon_timer_seeded ? aon_timer_set_time(&ts) : aon_timer_start(&ts);
    if (ok) {
        g_aon_timer_seeded = true;
    }

    return ok;
}

static void sleep_until_next_cycle(uint32_t sleep_sec) {
    sleep_sec = normalize_sleep_sec(sleep_sec);

    // The watchdog's hardware max (~8.3s) is far shorter than a wake
    // interval, and there's no way to feed it during either sleep_ms() or
    // xosc_dormant(). Disable it for the sleep and re-arm on the way out —
    // nothing can hang while the CPU itself is asleep, so this doesn't give
    // up any real protection, and every exit path below re-enables it.
    watchdog_disable();

    if (!VG_ENABLE_AON_DORMANT_SLEEP || !g_aon_timer_seeded) {
        printf("[cycle] sleeping with delay=%lus mode=sleep_ms\n", (unsigned long)sleep_sec);
        stdio_flush();
        sleep_ms(sleep_sec * 1000u);
        watchdog_enable(VG_WATCHDOG_TIMEOUT_MS, true);
        return;
    }

    struct timespec now_ts;
    if (!aon_timer_get_time(&now_ts) || now_ts.tv_sec <= 0) {
        printf("[cycle] aon timer unavailable, sleeping with mode=sleep_ms delay=%lus\n",
            (unsigned long)sleep_sec);
        stdio_flush();
        sleep_ms(sleep_sec * 1000u);
        watchdog_enable(VG_WATCHDOG_TIMEOUT_MS, true);
        return;
    }

    struct timespec wake_ts = now_ts;
    wake_ts.tv_sec += (time_t)sleep_sec;
    g_sleep_alarm_fired = false;

    aon_timer_alarm_handler_t previous_handler =
        aon_timer_enable_alarm(&wake_ts, sleep_alarm_handler, true);
    if ((intptr_t)previous_handler == PICO_ERROR_INVALID_ARG) {
        printf("[cycle] aon alarm setup failed, sleeping with mode=sleep_ms delay=%lus\n",
            (unsigned long)sleep_sec);
        stdio_flush();
        sleep_ms(sleep_sec * 1000u);
        watchdog_enable(VG_WATCHDOG_TIMEOUT_MS, true);
        return;
    }

    printf("[cycle] sleeping with delay=%lus mode=aon_dormant\n", (unsigned long)sleep_sec);
    stdio_flush();
    xosc_dormant();
    aon_timer_disable_alarm();
    watchdog_enable(VG_WATCHDOG_TIMEOUT_MS, true);

    if (!g_sleep_alarm_fired) {
        printf("[cycle] woke before rtc alarm fired\n");
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
    // forces a reboot instead of silently idling until the battery dies.
    watchdog_enable(VG_WATCHDOG_TIMEOUT_MS, true);

    printf("[main] config: node=%s zone=%s broker=%s:%d utc_offset_hours=%d\n",
        config.node_id, config.zone_id, config.mqtt_host, config.mqtt_port, (int)config.utc_offset_hours);
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
#if VG_ENABLE_LORA_TRANSPORT
    lora_transport_t lora_transport;
    lora_frame_buffer_t lora_rx_buffer;
    lora_transport_config_t lora_config = lora_transport_default_config();
    lora_frame_buffer_reset(&lora_rx_buffer);
    bool lora_ready = lora_transport_init(&lora_transport, &lora_config);
    lora_recent_command_t lora_recent_commands[VG_LORA_RECENT_COMMAND_COUNT] = {0};
    size_t lora_next_recent_command = 0u;
    if (lora_ready) {
        printf("[main] lora: uart=uart1 baud=%u tx=GP%u rx=GP%u aux=GP%d m0=GP%d m1=GP%d\n",
            (unsigned)lora_config.baud_rate,
            (unsigned)lora_config.tx_gpio,
            (unsigned)lora_config.rx_gpio,
            lora_config.aux_gpio,
            lora_config.m0_gpio,
            lora_config.m1_gpio);
    } else {
        printf("[main] lora init failed\n");
    }
#endif
    stdio_flush();

    // Forces exactly one reading on the first wake after a boot, regardless
    // of the active window, so a reboot (deliberate or watchdog-forced)
    // visibly confirms the board came back healthy and backfills whatever
    // reading interval was missed during the outage. Stays true across a
    // wifi/mqtt-timeout retry (via `continue`) since no reading has actually
    // happened yet in either case.
    bool is_first_wake = true;

    while (true) {
        const uint32_t wake_count = init_wake_count();
        bool reconnect_requested = false;
        bool reboot_requested = false;
        bool publish_requested = false;
        uint32_t sleep_sec = VG_TEMP_INTERVAL_MINUTES * 60u;
        uint32_t epoch_sec = 0u;
        bool time_synced = false;
#if VG_ENABLE_LORA_TRANSPORT
        bool lora_cycle_warmed = false;
        bool lora_cycle_available = true;
        uint8_t lora_frames_sent = 0;
        uint8_t lora_send_failures = 0;
        lora_pending_command_t lora_pending_command = {0};
        lora_command_window_stats_t lora_command_stats = {0};
#endif

        mqtt_node_init(&node, &config);

        printf("[cycle] start wake_count=%lu node=%s zone=%s interval_ms=%lu\n",
            (unsigned long)wake_count,
            config.node_id,
            config.zone_id,
            (unsigned long)config.publish_interval_ms);
        stdio_flush();

        printf("[cycle] connecting Wi-Fi\n");
        stdio_flush();
        if (!wifi_connect_with_timeout(&config, wifi_error, sizeof(wifi_error), VG_WIFI_CONNECT_TIMEOUT_MS)) {
            printf("[main] wifi failed: %s, sleeping\n", wifi_error);
            stdio_flush();
            cleanup_cycle(&node);
            sleep_until_next_cycle(sleep_sec);
            continue;
        }

        printf("[cycle] starting time sync\n");
        stdio_flush();
        time_sync_init();
        if (!wait_for_time_sync(VG_TIME_SYNC_TIMEOUT_MS)) {
            printf("[main] ntp timeout, continuing without synced time\n");
            stdio_flush();
        } else {
            epoch_sec = time_sync_epoch_sec();
            time_synced = epoch_sec != 0u;
            (void)aon_timer_sync_from_epoch(epoch_sec);
        }

        if (time_synced) {
            sleep_sec = seconds_until_next_wake(epoch_sec, config.utc_offset_hours);
        }

        printf("[cycle] connecting MQTT\n");
        stdio_flush();
        if (!wait_for_mqtt_connection(&node, VG_MQTT_CONNECT_TIMEOUT_MS)) {
            printf("[main] mqtt timeout err=%s, sleeping\n", node.last_error);
            stdio_flush();
            cleanup_cycle(&node);
            sleep_until_next_cycle(sleep_sec);
            continue;
        }

        poll_retained_window(&node, VG_MQTT_RETAINED_WINDOW_MS, &reconnect_requested, &reboot_requested);
        if (reboot_requested) {
            printf("[main] reboot requested\n");
            stdio_flush();
            cleanup_cycle(&node);
            // watchdog_reboot() schedules a hardware reset delay_ms in the
            // future -- it does NOT halt execution. Halt explicitly instead
            // of falling through to the rest of the loop, so nothing else
            // can run (and no other command can be accepted) in that gap.
            watchdog_reboot(0, 0, 100);
            while (true) {
                tight_loop_contents();
            }
        }

        if (reconnect_requested) {
            printf("[main] config changed, reconnecting immediately\n");
            stdio_flush();
            cleanup_cycle(&node);
            continue;
        }

#if VG_ENABLE_LORA_TRANSPORT
        if (lora_ready) {
            service_lora_command_window(
                &lora_transport,
                &lora_rx_buffer,
                &config,
                VG_LORA_COMMAND_INTAKE_WINDOW_MS,
                &lora_pending_command,
                lora_recent_commands,
                VG_LORA_RECENT_COMMAND_COUNT,
                &lora_command_stats
            );
        }
        const bool lora_publish_requested = lora_pending_command.type != LORA_PENDING_COMMAND_NONE;
#else
        const bool lora_publish_requested = false;
#endif

        if (time_synced) {
            sleep_sec = seconds_until_next_wake(epoch_sec, config.utc_offset_hours);
            if (is_first_wake) {
                printf("[cycle] first wake after boot, forcing a reading regardless of active window\n");
                stdio_flush();
            } else if (!lora_publish_requested && !is_active_window(epoch_sec, config.utc_offset_hours)) {
                const uint32_t local_sec = local_seconds_today(epoch_sec, config.utc_offset_hours);
                printf("[cycle] inactive local=%02lu:%02lu utc_offset_hours=%d no sensor reads next_wake=%lus\n",
                    (unsigned long)(local_sec / 3600u),
                    (unsigned long)((local_sec / 60u) % 60u),
                    (int)config.utc_offset_hours,
                    (unsigned long)sleep_sec);
                stdio_flush();
                cleanup_cycle(&node);
                sleep_until_next_cycle(sleep_sec);
                continue;
            }
        }

        if (!wait_for_canary_publish(&node, VG_MQTT_CANARY_TIMEOUT_MS)) {
            printf("[main] canary failed err=%s, continuing to state publish\n", node.last_error);
            stdio_flush();
        }

        publish_requested = mqtt_node_has_publish_request(&node);
        if (publish_requested) {
            mqtt_node_take_publish_request(&node);
        }

        if (VG_ENABLE_I2C_DIAGNOSTIC_SCAN) {
            sht40_scan_bus(&config);
        }
        float air_temperature_c = 0.0f;
        float humidity_percent = 0.0f;
        bool environment_valid = sht40_read(&config, &air_temperature_c, &humidity_percent);
        bool sht40_present = true;
        if (!environment_valid) {
            sht40_present = sht40_probe(&config);
            snprintf(
                node.last_error,
                sizeof(node.last_error),
                "sht40 read failed; 0x44 %s",
                sht40_present ? "present" : "missing"
            );
            printf("[main] %s; continuing with degraded publish\n", node.last_error);
            stdio_flush();
        }

        const bool read_soil = is_first_wake || publish_requested ||
            (time_synced ? should_read_soil_moisture(epoch_sec, config.utc_offset_hours)
                         : (wake_count % (VG_SOIL_INTERVAL_MINUTES / VG_TEMP_INTERVAL_MINUTES)) == 0u);
        bool soil_sensors_initialized = false;
        if (read_soil) {
            sensors_init(&config);
            soil_sensors_initialized = true;
        }
        printf("[cycle] sensors temp_c=%.2f humidity=%.2f soil=%s publish_requested=%s\n",
            (double)air_temperature_c,
            (double)humidity_percent,
            read_soil ? "yes" : "no",
            publish_requested ? "true" : "false");
        stdio_flush();

        const char *reason = is_first_wake ? "boot" : (publish_requested ? "request_reading" : "interval");
        is_first_wake = false;
        uint8_t successful_soil_reads = 0;
        bool all_mqtt_published = true;
#if VG_ENABLE_LORA_TRANSPORT
        if (lora_ready) {
            service_lora_command_window(
                &lora_transport,
                &lora_rx_buffer,
                &config,
                VG_LORA_COMMAND_WINDOW_MS,
                &lora_pending_command,
                lora_recent_commands,
                VG_LORA_RECENT_COMMAND_COUNT,
                &lora_command_stats
            );
            handle_pending_lora_command(
                &lora_transport,
                &config,
                &lora_pending_command,
                lora_recent_commands,
                VG_LORA_RECENT_COMMAND_COUNT,
                &lora_next_recent_command,
                air_temperature_c,
                humidity_percent,
                environment_valid,
                &soil_sensors_initialized,
                &lora_command_stats
            );
        }
#endif
        for (uint8_t ch = 0; ch < VG_ADS1115_CHANNEL_COUNT; ++ch) {
            sensor_snapshot_t ch_snapshot = {0};
            ch_snapshot.air_temperature_c = air_temperature_c;
            ch_snapshot.humidity_percent = humidity_percent;
            ch_snapshot.environment_valid = environment_valid;
            ch_snapshot.healthy = environment_valid;
            if (read_soil) {
                ch_snapshot.soil_moisture_read = sensors_read(&config, ch, &ch_snapshot);
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
                    node.last_error,
                    sizeof(node.last_error),
                    "sht40 read failed; 0x44 %s",
                    sht40_present ? "present" : "missing"
                );
            } else if (read_soil && !ch_snapshot.soil_moisture_read) {
                snprintf(
                    node.last_error,
                    sizeof(node.last_error),
                    "channel %u soil read failed",
                    (unsigned)ch
                );
            } else if (read_soil && !ch_snapshot.healthy) {
                snprintf(
                    node.last_error,
                    sizeof(node.last_error),
                    "channel %u raw outside calibration",
                    (unsigned)ch
                );
            } else {
                snprintf(node.last_error, sizeof(node.last_error), "%s", "none");
            }
            printf("[cycle] publishing channel %u node=%s reason=%s soil_read=%s moisture_raw=%u moisture_percent=%d\n",
                (unsigned)ch,
                config.channel_node_id[ch],
                reason,
                ch_snapshot.soil_moisture_read ? "true" : "false",
                ch_snapshot.moisture_raw,
                ch_snapshot.moisture_percent);
            stdio_flush();
            bool published = mqtt_node_publish_state(
                &node,
                &ch_snapshot,
                reason,
                wake_count,
                config.channel_node_id[ch]
            );
            if (!published) {
                service_mqtt_window(&node, 250u);
                published = mqtt_node_publish_state(
                    &node,
                    &ch_snapshot,
                    reason,
                    wake_count,
                    config.channel_node_id[ch]
                );
            }
            if (!published) {
                all_mqtt_published = false;
                printf("[main] channel %u publish failed err=%s\n", (unsigned)ch, node.last_error);
                stdio_flush();
            }
#if VG_ENABLE_LORA_TRANSPORT
            if (lora_ready &&
                lora_cycle_available &&
                lora_command_stats.executed_commands == 0u &&
                read_soil &&
                ch_snapshot.soil_moisture_read) {
                char lora_frame[VG_LORA_MAX_FRAME_SIZE + 1u] = {0};
                if (!lora_cycle_warmed) {
                    if (!lora_transport_send_frame(&lora_transport, "\n", 1u)) {
                        lora_cycle_available = false;
                        lora_send_failures++;
                        printf("[lora] warm-up send failed; skipping LoRa sends for this cycle\n");
                        stdio_flush();
                    }
                    sleep_ms(100);
                    lora_cycle_warmed = true;
                }
                if (lora_cycle_available) {
                    bool lora_formatted = lora_format_autonomous_channel_state_frame(
                        lora_frame,
                        sizeof(lora_frame),
                        &config,
                        &ch_snapshot,
                        ch,
                        reason,
                        wake_count,
                        (uint32_t)(to_ms_since_boot(get_absolute_time()) / 1000u)
                    );
                    if (lora_formatted &&
                        lora_transport_send_frame(&lora_transport, lora_frame, strlen(lora_frame))) {
                        lora_frames_sent++;
                        printf("[lora] sent channel %u node=%s bytes=%u\n",
                            (unsigned)ch,
                            config.channel_node_id[ch],
                            (unsigned)strlen(lora_frame));
                    } else {
                        lora_cycle_available = false;
                        lora_send_failures++;
                        printf("[lora] send failed channel %u node=%s formatted=%s; skipping remaining LoRa sends this cycle\n",
                            (unsigned)ch,
                            config.channel_node_id[ch],
                            lora_formatted ? "true" : "false");
                    }
                    stdio_flush();
                }
            }
#endif
            service_mqtt_window(&node, 100u);
#if VG_ENABLE_LORA_TRANSPORT
            if (lora_ready) {
                service_lora_command_window(
                    &lora_transport,
                    &lora_rx_buffer,
                    &config,
                    VG_LORA_COMMAND_WINDOW_MS,
                    &lora_pending_command,
                    lora_recent_commands,
                    VG_LORA_RECENT_COMMAND_COUNT,
                    &lora_command_stats
                );
                handle_pending_lora_command(
                    &lora_transport,
                    &config,
                    &lora_pending_command,
                    lora_recent_commands,
                    VG_LORA_RECENT_COMMAND_COUNT,
                    &lora_next_recent_command,
                    air_temperature_c,
                    humidity_percent,
                    environment_valid,
                    &soil_sensors_initialized,
                    &lora_command_stats
                );
            }
#endif
        }

        if (read_soil && successful_soil_reads == 0) {
            printf("[main] all soil channel reads failed; environment readings were still published\n");
            stdio_flush();
        }
#if VG_ENABLE_LORA_TRANSPORT
        if (lora_ready) {
            printf("[lora] post-telemetry command window open for %lums\n",
                (unsigned long)VG_LORA_POST_TELEMETRY_COMMAND_WINDOW_MS);
            stdio_flush();
            service_lora_command_window_and_handle(
                &lora_transport,
                &lora_rx_buffer,
                &config,
                VG_LORA_POST_TELEMETRY_COMMAND_WINDOW_MS,
                &lora_pending_command,
                lora_recent_commands,
                VG_LORA_RECENT_COMMAND_COUNT,
                &lora_next_recent_command,
                air_temperature_c,
                humidity_percent,
                environment_valid,
                &soil_sensors_initialized,
                &lora_command_stats
            );
            printf("[lora] post-telemetry command window closed\n");
            stdio_flush();
        }

        if (read_soil) {
            printf("[lora] cycle summary ready=%s sent=%u failures=%u available=%s\n",
                lora_ready ? "true" : "false",
                (unsigned)lora_frames_sent,
                (unsigned)lora_send_failures,
                lora_cycle_available ? "true" : "false");
            stdio_flush();
        }
#endif
#if VG_ENABLE_LORA_TRANSPORT
        log_lora_command_window_summary(&lora_command_stats);
#endif

        if (publish_requested && all_mqtt_published) {
            mqtt_node_mark_publish_request_handled(&node);
            drain_mqtt_window(&node, 1000u);
        } else if (publish_requested) {
            printf("[main] publish request incomplete, leaving command pending\n");
            stdio_flush();
        }

        sleep_sec = time_synced ? seconds_until_next_wake(epoch_sec, config.utc_offset_hours) : VG_TEMP_INTERVAL_MINUTES * 60u;

        printf("[main] published reason=%s wake_count=%lu next_sleep=%lus\n",
            reason,
            (unsigned long)wake_count,
            (unsigned long)sleep_sec);
        stdio_flush();

        cleanup_cycle(&node);
        sleep_until_next_cycle(sleep_sec);
    }
}
