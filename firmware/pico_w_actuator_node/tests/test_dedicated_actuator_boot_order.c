#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_source(void) {
    FILE *file = fopen(VG_DEDICATED_MAIN_SOURCE, "rb");
    assert(file != NULL);
    assert(fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file);
    assert(length > 0);
    rewind(file);

    char *source = calloc((size_t)length + 1u, 1u);
    assert(source != NULL);
    assert(fread(source, 1, (size_t)length, file) == (size_t)length);
    assert(fclose(file) == 0);
    return source;
}

int main(void) {
    char *source = read_source();
    const char *load = strstr(source, "node_config_load(&config);");
    const char *safe_off = strstr(source, "actuator_relays_init_safe(&config);");
    const char *stdio = strstr(source, "stdio_init_all();");
    const char *delay = strstr(source, "sleep_ms(3000);");
    const char *provisioning = strstr(source, "wait_for_usb_provisioning(&config);");
    const char *journal = strstr(source, "vg_dedicated_actuator_journal_boot_load");
    const char *wifi = strstr(source, "wifi_connect_with_retry(&config");

    assert(load != NULL && safe_off != NULL && stdio != NULL && delay != NULL);
    assert(provisioning != NULL && journal != NULL && wifi != NULL);
    assert(load < safe_off);
    assert(safe_off < stdio);
    assert(safe_off < delay);
    assert(safe_off < provisioning);
    assert(safe_off < journal);
    assert(safe_off < wifi);

    free(source);
    puts("dedicated_actuator_boot_order_tests: passed");
    return 0;
}
