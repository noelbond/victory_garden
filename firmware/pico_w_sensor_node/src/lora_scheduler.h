#pragma once

#include <stdbool.h>
#include <stdint.h>

// This module owns wake policy for the LoRa-primary runtime. It intentionally
// has no Pico SDK, radio, or network dependency so the scheduler can be
// exercised on a host.

enum {
    LORA_SCHEDULER_SECONDS_PER_DAY = 24u * 60u * 60u,
    LORA_SCHEDULER_DEFAULT_COMBINED_INTERVAL_MS = 15u * 60u * 1000u,
    LORA_SCHEDULER_DEFAULT_MAX_WAKE_DELAY_MS = 15u * 60u * 1000u,
    LORA_SCHEDULER_MIN_WAKE_DELAY_MS = 1000u,
    // These approved production-policy defaults deliberately live here rather
    // than in Pico configuration so scheduler tests require no Pico SDK.
    LORA_SCHEDULER_DEFAULT_ACTIVE_START_HOUR = 6u,
    LORA_SCHEDULER_DEFAULT_ACTIVE_END_HOUR = 20u,
};

typedef struct {
    // A sensing slot always acquires the environment and every configured soil
    // channel. Keeping one deadline makes the production cadence indivisible.
    uint32_t combined_interval_ms;
    uint32_t max_wake_delay_ms;
    uint8_t active_start_hour;
    uint8_t active_end_hour;
} lora_scheduler_config_t;

typedef struct {
    // This is intentionally a snapshot supplied by the future wall-clock
    // provider. A cold boot supplies valid=false until it is synchronized.
    bool valid;
    uint32_t seconds_since_midnight;
} lora_wall_clock_t;

typedef struct {
    lora_scheduler_config_t config;
    uint32_t next_combined_due_ms;
    bool initialized;
} lora_scheduler_t;

typedef struct {
    bool wall_clock_valid;
    bool active_window;
    bool combined_due;
    // Always non-zero and no greater than max_wake_delay_ms. This keeps wake
    // opportunities bounded while the wall clock is invalid or it is night.
    uint32_t next_wake_delay_ms;
} lora_scheduler_plan_t;

lora_scheduler_config_t lora_scheduler_default_config(void);
bool lora_scheduler_init(
    lora_scheduler_t *scheduler,
    const lora_scheduler_config_t *config,
    uint32_t monotonic_now_ms
);
lora_scheduler_plan_t lora_scheduler_plan(
    const lora_scheduler_t *scheduler,
    uint32_t monotonic_now_ms,
    const lora_wall_clock_t *wall_clock
);
void lora_scheduler_mark_combined_complete(lora_scheduler_t *scheduler, uint32_t monotonic_now_ms);
