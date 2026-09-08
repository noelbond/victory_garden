#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "lora_scheduler.h"

static lora_wall_clock_t valid_wall_clock(uint8_t hour) {
    return (lora_wall_clock_t){
        .valid = true,
        .seconds_since_midnight = (uint32_t)hour * 60u * 60u,
    };
}

static void assert_bounded_delay(const lora_scheduler_plan_t *plan) {
    assert(plan->next_wake_delay_ms >= LORA_SCHEDULER_MIN_WAKE_DELAY_MS);
    assert(plan->next_wake_delay_ms <= LORA_SCHEDULER_DEFAULT_MAX_WAKE_DELAY_MS);
}

static void test_invalid_wall_clock_runs_initial_degraded_cycle(void) {
    lora_scheduler_t scheduler;
    const lora_scheduler_config_t config = lora_scheduler_default_config();
    const lora_wall_clock_t invalid_time = { .valid = false };

    assert(lora_scheduler_init(&scheduler, &config, 1234u));
    const lora_scheduler_plan_t plan = lora_scheduler_plan(&scheduler, 1234u, &invalid_time);
    assert(!plan.wall_clock_valid);
    assert(plan.active_window);
    assert(plan.combined_due);
    assert_bounded_delay(&plan);
}

static void test_combined_cadence_advances_after_attempt(void) {
    lora_scheduler_t scheduler;
    const lora_scheduler_config_t config = lora_scheduler_default_config();
    const lora_wall_clock_t invalid_time = { .valid = false };
    const uint32_t completed_at_ms = 5000u;

    assert(lora_scheduler_init(&scheduler, &config, 0u));
    lora_scheduler_mark_combined_complete(&scheduler, completed_at_ms);

    lora_scheduler_plan_t plan = lora_scheduler_plan(&scheduler, completed_at_ms, &invalid_time);
    assert(!plan.combined_due);
    assert(plan.next_wake_delay_ms == config.combined_interval_ms);

    plan = lora_scheduler_plan(
        &scheduler,
        completed_at_ms + config.combined_interval_ms - 1u,
        &invalid_time
    );
    assert(!plan.combined_due);
    assert(plan.next_wake_delay_ms == LORA_SCHEDULER_MIN_WAKE_DELAY_MS);

    plan = lora_scheduler_plan(
        &scheduler,
        completed_at_ms + config.combined_interval_ms,
        &invalid_time
    );
    assert(plan.combined_due);
    assert_bounded_delay(&plan);
}

static void test_valid_wall_clock_gates_active_window(void) {
    lora_scheduler_t scheduler;
    const lora_scheduler_config_t config = lora_scheduler_default_config();

    assert(config.combined_interval_ms == 15u * 60u * 1000u);
    assert(config.active_start_hour == 6u);
    assert(config.active_end_hour == 20u);
    assert(lora_scheduler_init(&scheduler, &config, 0u));

    lora_scheduler_plan_t plan = lora_scheduler_plan(&scheduler, 0u, &(lora_wall_clock_t){ .valid = true, .seconds_since_midnight = 6u * 60u * 60u });
    assert(plan.wall_clock_valid);
    assert(plan.active_window);
    assert(plan.combined_due);
    assert_bounded_delay(&plan);

    const lora_wall_clock_t before_start = valid_wall_clock(5u);
    plan = lora_scheduler_plan(&scheduler, 0u, &before_start);
    assert(plan.wall_clock_valid);
    assert(!plan.active_window);
    assert(!plan.combined_due);
    assert(plan.next_wake_delay_ms == config.max_wake_delay_ms);

    const lora_wall_clock_t after_end = valid_wall_clock(20u);
    plan = lora_scheduler_plan(&scheduler, 0u, &after_end);
    assert(plan.wall_clock_valid);
    assert(!plan.active_window);
    assert(!plan.combined_due);
    assert(plan.next_wake_delay_ms == config.max_wake_delay_ms);
}

static void test_invalid_wall_clock_values_degrade_safely(void) {
    lora_scheduler_t scheduler;
    const lora_scheduler_config_t config = lora_scheduler_default_config();
    const lora_wall_clock_t malformed_time = {
        .valid = true,
        .seconds_since_midnight = LORA_SCHEDULER_SECONDS_PER_DAY,
    };

    assert(lora_scheduler_init(&scheduler, &config, 0u));
    const lora_scheduler_plan_t plan = lora_scheduler_plan(&scheduler, 0u, &malformed_time);
    assert(!plan.wall_clock_valid);
    assert(plan.active_window);
    assert(plan.combined_due);
    assert_bounded_delay(&plan);
}

static void test_wall_clock_transitions_do_not_change_monotonic_deadline(void) {
    lora_scheduler_t scheduler;
    const lora_scheduler_config_t config = lora_scheduler_default_config();
    const lora_wall_clock_t invalid_time = { .valid = false };
    const lora_wall_clock_t outside_window = valid_wall_clock(21u);
    const lora_wall_clock_t inside_window = valid_wall_clock(7u);

    assert(lora_scheduler_init(&scheduler, &config, 0u));
    lora_scheduler_mark_combined_complete(&scheduler, 1000u);

    lora_scheduler_plan_t plan = lora_scheduler_plan(&scheduler, 2000u, &invalid_time);
    assert(!plan.combined_due);

    plan = lora_scheduler_plan(&scheduler, 2000u, &outside_window);
    assert(!plan.active_window);
    assert(!plan.combined_due);

    plan = lora_scheduler_plan(&scheduler, 2000u, &inside_window);
    assert(plan.active_window);
    assert(!plan.combined_due);
    assert(plan.next_wake_delay_ms == config.combined_interval_ms - 1000u);
}

static void test_monotonic_deadline_is_wrap_safe(void) {
    lora_scheduler_t scheduler;
    const lora_scheduler_config_t config = lora_scheduler_default_config();
    const lora_wall_clock_t invalid_time = { .valid = false };
    const uint32_t completed_at_ms = UINT32_MAX - 1000u;

    assert(lora_scheduler_init(&scheduler, &config, completed_at_ms));
    lora_scheduler_mark_combined_complete(&scheduler, completed_at_ms);

    lora_scheduler_plan_t plan = lora_scheduler_plan(&scheduler, UINT32_MAX, &invalid_time);
    assert(!plan.combined_due);
    assert(plan.next_wake_delay_ms == config.combined_interval_ms - 1000u);

    plan = lora_scheduler_plan(
        &scheduler,
        completed_at_ms + config.combined_interval_ms,
        &invalid_time
    );
    assert(plan.combined_due);
    assert_bounded_delay(&plan);
}

int main(void) {
    test_invalid_wall_clock_runs_initial_degraded_cycle();
    test_combined_cadence_advances_after_attempt();
    test_valid_wall_clock_gates_active_window();
    test_invalid_wall_clock_values_degrade_safely();
    test_wall_clock_transitions_do_not_change_monotonic_deadline();
    test_monotonic_deadline_is_wrap_safe();
    puts("lora_scheduler_tests: passed");
    return 0;
}
