#include "lora_scheduler.h"

#include <limits.h>
#include <string.h>

static bool config_valid(const lora_scheduler_config_t *config) {
    return config &&
        config->combined_interval_ms > 0u &&
        config->max_wake_delay_ms >= LORA_SCHEDULER_MIN_WAKE_DELAY_MS &&
        config->active_start_hour < 24u &&
        config->active_end_hour <= 24u &&
        config->active_start_hour < config->active_end_hour &&
        config->combined_interval_ms <= INT32_MAX;
}

static bool deadline_due(uint32_t now_ms, uint32_t deadline_ms) {
    // Intervals are constrained below INT32_MAX, making this wrap-safe for
    // normal 32-bit monotonic timer rollover.
    return (int32_t)(now_ms - deadline_ms) >= 0;
}

static uint32_t deadline_remaining(uint32_t now_ms, uint32_t deadline_ms) {
    return deadline_due(now_ms, deadline_ms) ? 0u : deadline_ms - now_ms;
}

static bool wall_clock_valid(const lora_wall_clock_t *wall_clock) {
    return wall_clock && wall_clock->valid &&
        wall_clock->seconds_since_midnight < LORA_SCHEDULER_SECONDS_PER_DAY;
}

static bool wall_clock_in_active_window(
    const lora_scheduler_config_t *config,
    const lora_wall_clock_t *wall_clock
) {
    const uint32_t hour = wall_clock->seconds_since_midnight / 3600u;
    return hour >= config->active_start_hour && hour < config->active_end_hour;
}

static uint32_t milliseconds_until_active_window(
    const lora_scheduler_config_t *config,
    const lora_wall_clock_t *wall_clock
) {
    const uint32_t start_seconds = (uint32_t)config->active_start_hour * 3600u;
    const uint32_t now_seconds = wall_clock->seconds_since_midnight;
    const uint32_t wait_seconds = now_seconds < start_seconds
        ? start_seconds - now_seconds
        : (LORA_SCHEDULER_SECONDS_PER_DAY - now_seconds) + start_seconds;

    // The configured window is checked before this function, so wait_seconds
    // is non-zero. Saturate instead of allowing a multiplication overflow.
    return wait_seconds > UINT32_MAX / 1000u ? UINT32_MAX : wait_seconds * 1000u;
}

static uint32_t bounded_delay(uint32_t proposed_ms, uint32_t max_wake_delay_ms) {
    uint32_t delay_ms = proposed_ms;
    if (delay_ms > max_wake_delay_ms) {
        delay_ms = max_wake_delay_ms;
    }
    return delay_ms < LORA_SCHEDULER_MIN_WAKE_DELAY_MS
        ? LORA_SCHEDULER_MIN_WAKE_DELAY_MS
        : delay_ms;
}

lora_scheduler_config_t lora_scheduler_default_config(void) {
    return (lora_scheduler_config_t){
        .combined_interval_ms = LORA_SCHEDULER_DEFAULT_COMBINED_INTERVAL_MS,
        .max_wake_delay_ms = LORA_SCHEDULER_DEFAULT_MAX_WAKE_DELAY_MS,
        .active_start_hour = LORA_SCHEDULER_DEFAULT_ACTIVE_START_HOUR,
        .active_end_hour = LORA_SCHEDULER_DEFAULT_ACTIVE_END_HOUR,
    };
}

bool lora_scheduler_init(
    lora_scheduler_t *scheduler,
    const lora_scheduler_config_t *config,
    uint32_t monotonic_now_ms
) {
    if (!scheduler || !config_valid(config)) {
        return false;
    }

    memset(scheduler, 0, sizeof(*scheduler));
    scheduler->config = *config;
    // A new boot is immediately eligible for one degraded combined sensing
    // cycle. It must never wait for wall-clock synchronization before becoming
    // useful.
    scheduler->next_combined_due_ms = monotonic_now_ms;
    scheduler->initialized = true;
    return true;
}

lora_scheduler_plan_t lora_scheduler_plan(
    const lora_scheduler_t *scheduler,
    uint32_t monotonic_now_ms,
    const lora_wall_clock_t *wall_clock
) {
    lora_scheduler_plan_t plan = {
        .next_wake_delay_ms = LORA_SCHEDULER_MIN_WAKE_DELAY_MS,
    };
    if (!scheduler || !scheduler->initialized) {
        return plan;
    }

    plan.wall_clock_valid = wall_clock_valid(wall_clock);
    // Invalid wall time deliberately degrades to the relative schedule: the
    // node remains active on its normal cadence rather than blocking or
    // guessing the 06:00-20:00 policy.
    plan.active_window = !plan.wall_clock_valid ||
        wall_clock_in_active_window(&scheduler->config, wall_clock);

    if (!plan.active_window) {
        plan.next_wake_delay_ms = bounded_delay(
            milliseconds_until_active_window(&scheduler->config, wall_clock),
            scheduler->config.max_wake_delay_ms
        );
        return plan;
    }

    plan.combined_due = deadline_due(monotonic_now_ms, scheduler->next_combined_due_ms);
    plan.next_wake_delay_ms = bounded_delay(
        deadline_remaining(monotonic_now_ms, scheduler->next_combined_due_ms),
        scheduler->config.max_wake_delay_ms
    );
    return plan;
}

void lora_scheduler_mark_combined_complete(lora_scheduler_t *scheduler, uint32_t monotonic_now_ms) {
    if (!scheduler || !scheduler->initialized) {
        return;
    }
    scheduler->next_combined_due_ms = monotonic_now_ms + scheduler->config.combined_interval_ms;
}
