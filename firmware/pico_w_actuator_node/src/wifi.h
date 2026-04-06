#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "config.h"

bool wifi_init_and_connect(const node_config_t *config, char *error, size_t error_size);
void wifi_poll(void);
bool wifi_is_connected(void);
int wifi_link_status(void);
int32_t wifi_rssi(void);
bool wifi_ip_string(char *out, size_t out_size);
void wifi_deinit(void);
