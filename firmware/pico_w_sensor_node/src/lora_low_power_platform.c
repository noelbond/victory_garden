#include "lora_low_power_platform.h"

#include <hardware/clocks.h>
#include <hardware/sync.h>
#include <hardware/watchdog.h>
#include <pico/stdlib.h>

enum {
    // RP2040's watchdog maximum is about 8.3 seconds. Keep each ROSC WFI
    // segment below that limit so an absent timer IRQ causes an explicit
    // watchdog reset instead of an unbounded wait.
    LORA_LOW_POWER_WFI_SEGMENT_MS = 7000u,
    LORA_LOW_POWER_WATCHDOG_TIMEOUT_MS = 8000u,
};

static volatile bool g_timer_alarm_fired;
static uint32_t g_rosc_hz;
static uint32_t g_sys_hz;
static uint32_t g_usb_hz;

static int64_t timer_alarm_handler(alarm_id_t id, void *user_data) {
    (void)id;
    (void)user_data;
    g_timer_alarm_fired = true;
    return 0;
}

static bool sleep_one_rosc_segment(uint32_t delay_ms) {
    g_timer_alarm_fired = false;
    if (add_alarm_in_ms(delay_ms, timer_alarm_handler, NULL, true) < 0) {
        return false;
    }

    // The hardware timer is clocked from clk_ref. Move both reference and
    // system clocks to ROSC before WFI. XOSC deliberately remains running:
    // RP2040's watchdog tick derives from XOSC, so disabling it would remove
    // the independent reset escape for a missing ROSC timer IRQ.
    clock_configure_undivided(clk_ref,
                              CLOCKS_CLK_REF_CTRL_SRC_VALUE_ROSC_CLKSRC_PH,
                              0, g_rosc_hz);
    clock_configure_undivided(clk_sys,
                              CLOCKS_CLK_SYS_CTRL_SRC_VALUE_CLKSRC_CLK_SYS_AUX,
                              CLOCKS_CLK_SYS_CTRL_AUXSRC_VALUE_ROSC_CLKSRC,
                              g_rosc_hz);
    while (!g_timer_alarm_fired) {
        __wfi();
    }

    clock_configure_undivided(clk_ref,
                              CLOCKS_CLK_REF_CTRL_SRC_VALUE_XOSC_CLKSRC,
                              0, XOSC_HZ);
    clock_configure_undivided(clk_sys,
                              CLOCKS_CLK_SYS_CTRL_SRC_VALUE_CLKSRC_CLK_SYS_AUX,
                              CLOCKS_CLK_SYS_CTRL_AUXSRC_VALUE_CLKSRC_PLL_SYS,
                              g_sys_hz);
    clock_configure_undivided(clk_usb, 0,
                              CLOCKS_CLK_USB_CTRL_AUXSRC_VALUE_CLKSRC_PLL_USB,
                              g_usb_hz);
    return true;
}

bool lora_low_power_platform_init(void) {
    const uint32_t rosc_khz = frequency_count_khz(CLOCKS_FC0_SRC_VALUE_ROSC_CLKSRC);
    if (rosc_khz == 0u) {
        return false;
    }

    g_rosc_hz = rosc_khz * KHZ;
    g_sys_hz = clock_get_hz(clk_sys);
    g_usb_hz = clock_get_hz(clk_usb);
    return g_sys_hz != 0u && g_usb_hz != 0u;
}

uint32_t lora_low_power_platform_monotonic_ms(void) {
    return (uint32_t)to_ms_since_boot(get_absolute_time());
}

lora_wall_clock_t lora_low_power_platform_wall_clock(void) {
    // No wall-clock provider exists in this target yet. A later gateway time
    // sync step replaces this adapter function without changing the scheduler.
    return (lora_wall_clock_t){ .valid = false, .seconds_since_midnight = 0u };
}

bool lora_low_power_platform_sleep_ms(uint32_t delay_ms) {
    if (delay_ms == 0u || g_rosc_hz == 0u || g_sys_hz == 0u || g_usb_hz == 0u) {
        return false;
    }

    uint32_t remaining_ms = delay_ms;
    watchdog_enable(LORA_LOW_POWER_WATCHDOG_TIMEOUT_MS, false);
    while (remaining_ms > 0u) {
        const uint32_t segment_ms = remaining_ms > LORA_LOW_POWER_WFI_SEGMENT_MS
            ? LORA_LOW_POWER_WFI_SEGMENT_MS
            : remaining_ms;
        if (!sleep_one_rosc_segment(segment_ms)) {
            watchdog_disable();
            return false;
        }
        // If the timer IRQ does not arrive, the watchdog remains armed and
        // resets the Pico. A successful bounded wake reaches this point.
        watchdog_update();
        remaining_ms -= segment_ms;
    }
    watchdog_disable();
    return true;
}
