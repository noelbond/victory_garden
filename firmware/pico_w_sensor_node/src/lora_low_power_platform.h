#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "lora_scheduler.h"

// Pico-specific support for the LoRa-primary runtime. Scheduling policy stays
// in lora_scheduler; this adapter only supplies monotonic time, the currently
// unavailable wall-clock snapshot, and bounded ROSC WFI sleep.

bool lora_low_power_platform_init(void);
uint32_t lora_low_power_platform_monotonic_ms(void);
lora_wall_clock_t lora_low_power_platform_wall_clock(void);
bool lora_low_power_platform_sleep_ms(uint32_t delay_ms);
