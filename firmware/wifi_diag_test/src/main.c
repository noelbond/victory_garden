#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/cyw43_arch.h"

int main(void) {
    stdio_init_all();
    sleep_ms(3000);
    printf("[diag] boot\n");

    int init_rc = cyw43_arch_init();
    printf("[diag] cyw43_arch_init rc=%d\n", init_rc);
    if (init_rc) {
        printf("[diag] cyw43 init failed, halting\n");
        while (true) {
            sleep_ms(1000);
        }
    }

    cyw43_arch_enable_sta_mode();
    printf("[diag] sta mode enabled, attempting connect to dummy network\n");

    for (int attempt = 1; attempt <= 20; attempt++) {
        int rc = cyw43_arch_wifi_connect_timeout_ms("DiagnosticTestNetwork", "testpassword123", CYW43_AUTH_WPA2_MIXED_PSK, 7000);
        printf("[diag] attempt=%d connect rc=%d\n", attempt, rc);
        sleep_ms(3000);
    }

    printf("[diag] done\n");
    while (true) {
        sleep_ms(1000);
    }
}
