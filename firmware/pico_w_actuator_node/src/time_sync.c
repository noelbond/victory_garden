#include "time_sync.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "config.h"
#include "lwip/apps/sntp.h"
#include "pico/cyw43_arch.h"
#include "pico/stdlib.h"
#include "wifi.h"

#define VG_TIME_SYNC_MIN_VALID_EPOCH_SECONDS 1577836800u
#define VG_TIME_SYNC_TRUST_MAX_AGE_US (2ull * 60ull * 60ull * 1000000ull)

typedef struct {
    bool initialized;
    bool synced;
    uint64_t synced_epoch_us;
    uint64_t synced_boot_us;
} time_sync_runtime_t;

static time_sync_runtime_t g_time_sync;

void vg_time_sync_set_epoch_us(uint32_t sec, uint32_t usec) {
    // Do not convert a zero/obviously pre-deployment SNTP sample into
    // authority to energize a relay. A later valid sample restores trust.
    if (sec < VG_TIME_SYNC_MIN_VALID_EPOCH_SECONDS || usec >= 1000000u) {
        return;
    }

    g_time_sync.synced = true;
    g_time_sync.synced_epoch_us = ((uint64_t)sec * 1000000ull) + usec;
    g_time_sync.synced_boot_us = to_us_since_boot(get_absolute_time());
}

static void format_unsynced_time(char *out, size_t out_size) {
    uint32_t seconds = to_ms_since_boot(get_absolute_time()) / 1000u;
    snprintf(out, out_size, "1970-01-01T00:%02u:%02uZ", (seconds / 60u) % 60u, seconds % 60u);
}

void time_sync_init(void) {
    if (g_time_sync.initialized) {
        return;
    }

    cyw43_arch_lwip_begin();
    sntp_setoperatingmode(SNTP_OPMODE_POLL);
    sntp_setservername(0, VG_DEFAULT_NTP_SERVER);
    sntp_init();
    cyw43_arch_lwip_end();

    g_time_sync.initialized = true;
}

void time_sync_poll(void) {
    if (!g_time_sync.initialized && wifi_is_connected()) {
        time_sync_init();
    }
}

bool time_sync_ready(void) {
    if (!g_time_sync.synced) {
        return false;
    }

    uint64_t now_boot_us = to_us_since_boot(get_absolute_time());
    return now_boot_us >= g_time_sync.synced_boot_us &&
           now_boot_us - g_time_sync.synced_boot_us <= VG_TIME_SYNC_TRUST_MAX_AGE_US;
}

bool time_sync_current_epoch_seconds(int64_t *epoch_seconds_out) {
    if (!epoch_seconds_out || !time_sync_ready()) {
        return false;
    }

    uint64_t now_us = g_time_sync.synced_epoch_us +
                      (to_us_since_boot(get_absolute_time()) - g_time_sync.synced_boot_us);
    *epoch_seconds_out = (int64_t)(now_us / 1000000ull);
    return true;
}

void time_sync_format_iso8601(char *out, size_t out_size) {
    if (!out || out_size == 0) {
        return;
    }

    if (!g_time_sync.synced) {
        format_unsynced_time(out, out_size);
        return;
    }

    uint64_t now_us = g_time_sync.synced_epoch_us +
                      (to_us_since_boot(get_absolute_time()) - g_time_sync.synced_boot_us);
    time_t now_sec = (time_t)(now_us / 1000000ull);
    struct tm utc_tm;
    if (!gmtime_r(&now_sec, &utc_tm)) {
        format_unsynced_time(out, out_size);
        return;
    }

    strftime(out, out_size, "%Y-%m-%dT%H:%M:%SZ", &utc_tm);
}
