#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "config.h"

uint32_t save_and_disable_interrupts(void) {
    return 0u;
}

void restore_interrupts(uint32_t status) {
    (void)status;
}

void flash_range_erase(uint32_t flash_offs, size_t count) {
    (void)flash_offs;
    (void)count;
}

void flash_range_program(uint32_t flash_offs, const uint8_t *data, size_t count) {
    (void)flash_offs;
    (void)data;
    (void)count;
}

static void payload_with_channels(char *out, size_t out_size, const char *channels_json) {
    const int written = snprintf(
        out,
        out_size,
        "{\"wifi_ssid\":\"ssid\",\"wifi_password\":\"password\",\"mqtt_host\":\"broker\",\"mqtt_port\":1883,\"node_id\":\"package\",\"zone_id\":\"zone-a\",\"channels\":[%s]}",
        channels_json
    );
    assert(written > 0 && (size_t)written < out_size);
}

static bool apply(const char *channels_json, char *error, size_t error_size, node_config_t *config) {
    char payload[1800];
    payload_with_channels(payload, sizeof(payload), channels_json);
    node_config_reset_defaults(config);
    return node_config_apply_provision_json(config, payload, error, error_size);
}

static void test_exact_canonical_channels_are_accepted(void) {
    node_config_t config;
    char error[128] = {0};
    assert(apply(
        "{\"node_id\":\"package-ch0\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch2\"},{\"node_id\":\"package-ch3\"}",
        error, sizeof(error), &config
    ));
    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        char expected[VG_MAX_NODE_ID_LEN];
        snprintf(expected, sizeof(expected), "package-ch%u", (unsigned)channel);
        assert(strcmp(config.channel_node_id[channel], expected) == 0);
    }
}

static void test_wrong_cardinality_is_rejected(void) {
    const char *three =
        "{\"node_id\":\"package-ch0\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch2\"}";
    const char *five =
        "{\"node_id\":\"package-ch0\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch2\"},{\"node_id\":\"package-ch3\"},{\"node_id\":\"package-ch4\"}";
    node_config_t config;
    char error[128] = {0};
    assert(!apply(three, error, sizeof(error), &config));
    assert(!apply(five, error, sizeof(error), &config));
    assert(strcmp(error, "channels array must contain exactly four entries") == 0);
}

static void test_noncanonical_channel_identities_are_rejected(void) {
    const char *duplicate =
        "{\"node_id\":\"package-ch0\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch3\"}";
    const char *reordered =
        "{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch0\"},{\"node_id\":\"package-ch2\"},{\"node_id\":\"package-ch3\"}";
    const char *wrong_package =
        "{\"node_id\":\"other-ch0\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch2\"},{\"node_id\":\"package-ch3\"}";
    const char *out_of_range =
        "{\"node_id\":\"package-ch0\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch2\"},{\"node_id\":\"package-ch4\"}";
    node_config_t config;
    char error[128] = {0};

    assert(!apply(duplicate, error, sizeof(error), &config));
    assert(!apply(reordered, error, sizeof(error), &config));
    assert(!apply(wrong_package, error, sizeof(error), &config));
    assert(!apply(out_of_range, error, sizeof(error), &config));
    assert(strcmp(error, "channel node_id does not match package identity") == 0);
}

static void test_overlong_provisioning_identities_are_rejected(void) {
    node_config_t config;
    char error[128] = {0};
    char overlong[33];
    char payload[1800];
    memset(overlong, 'x', 32);
    overlong[32] = '\0';

    assert(!apply(
        "{\"node_id\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch2\"},{\"node_id\":\"package-ch3\"}",
        error, sizeof(error), &config
    ));
    assert(strcmp(error, "channel node_id missing") == 0);

    const int written = snprintf(
        payload, sizeof(payload),
        "{\"wifi_ssid\":\"ssid\",\"wifi_password\":\"password\",\"mqtt_host\":\"broker\",\"mqtt_port\":1883,\"node_id\":\"%s\",\"zone_id\":\"zone-a\",\"channels\":[{\"node_id\":\"package-ch0\"},{\"node_id\":\"package-ch1\"},{\"node_id\":\"package-ch2\"},{\"node_id\":\"package-ch3\"}]}",
        overlong
    );
    assert(written > 0 && (size_t)written < sizeof(payload));
    node_config_reset_defaults(&config);
    assert(!node_config_apply_provision_json(&config, payload, error, sizeof(error)));
    assert(strcmp(error, "required provisioning fields missing") == 0);
}

int main(void) {
    test_exact_canonical_channels_are_accepted();
    test_wrong_cardinality_is_rejected();
    test_noncanonical_channel_identities_are_rejected();
    test_overlong_provisioning_identities_are_rejected();
    puts("sensor_provisioning_channels_tests: passed");
    return 0;
}
