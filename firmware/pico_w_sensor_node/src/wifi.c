#include "wifi.h"

#include <stdio.h>
#include <string.h>

#include "pico/cyw43_arch.h"
#include "lwip/ip4_addr.h"
#include "lwip/netif.h"

static bool wifi_initialized = false;

static bool wifi_has_ip_locked(void) {
    if (!netif_default) {
        return false;
    }
    const ip4_addr_t *addr = netif_ip4_addr(netif_default);
    return addr && !ip4_addr_isany_val(*addr);
}

static void set_error(char *error, size_t error_size, const char *message) {
    if (error && error_size > 0) {
        snprintf(error, error_size, "%s", message);
    }
}

bool wifi_init_and_connect(const node_config_t *config, char *error, size_t error_size) {
    if (!wifi_initialized) {
        if (cyw43_arch_init()) {
            set_error(error, error_size, "cyw43 init failed");
            return false;
        }
        wifi_initialized = true;
    }

    cyw43_arch_enable_sta_mode();
    int rc = cyw43_arch_wifi_connect_timeout_ms(
        config->wifi_ssid,
        config->wifi_password,
        CYW43_AUTH_WPA2_MIXED_PSK,
        30000
    );
    if (rc != 0) {
        char message[64];
        snprintf(message, sizeof(message), "wifi connect failed rc=%d", rc);
        set_error(error, error_size, message);
        return false;
    }
    return true;
}

void wifi_poll(void) {
    (void)wifi_initialized;
}

int wifi_link_status(void) {
    if (!wifi_initialized) {
        return CYW43_LINK_DOWN;
    }
    int status = CYW43_LINK_DOWN;
    cyw43_arch_lwip_begin();
    status = cyw43_wifi_link_status(&cyw43_state, CYW43_ITF_STA);
    cyw43_arch_lwip_end();
    return status;
}

bool wifi_is_connected(void) {
    if (!wifi_initialized) {
        return false;
    }

    bool connected = false;
    cyw43_arch_lwip_begin();
    int status = cyw43_wifi_link_status(&cyw43_state, CYW43_ITF_STA);
    connected = (status == CYW43_LINK_UP) || wifi_has_ip_locked();
    cyw43_arch_lwip_end();
    return connected;
}

int32_t wifi_rssi(void) {
    int32_t rssi = 0;
    if (!wifi_is_connected()) {
        return 0;
    }
    cyw43_arch_lwip_begin();
    int rc = cyw43_wifi_get_rssi(&cyw43_state, &rssi);
    cyw43_arch_lwip_end();
    if (rc != 0) {
        return 0;
    }
    return rssi;
}

bool wifi_ip_string(char *out, size_t out_size) {
    if (!out || out_size == 0) {
        return false;
    }
    bool ok = false;
    cyw43_arch_lwip_begin();
    if (wifi_has_ip_locked()) {
        const ip4_addr_t *addr = netif_ip4_addr(netif_default);
        if (addr) {
            snprintf(out, out_size, "%s", ip4addr_ntoa(addr));
            ok = true;
        }
    }
    cyw43_arch_lwip_end();
    if (!ok) {
        return false;
    }
    return true;
}

void wifi_deinit(void) {
    /* Do not call cyw43_arch_deinit() — reinitializing CYW43 after deinit
       hangs permanently with threadsafe_background (pico-sdk issue #980).
       Leave the arch initialized; wifi_init_and_connect will reconnect. */
}
