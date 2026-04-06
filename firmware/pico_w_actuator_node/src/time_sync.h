#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

void time_sync_init(void);
void time_sync_poll(void);
bool time_sync_ready(void);
void time_sync_format_iso8601(char *out, size_t out_size);
void vg_time_sync_set_epoch_us(uint32_t sec, uint32_t usec);
