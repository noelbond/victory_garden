// Minimal RP2040 low-power timed-wake feasibility executable for the
// LoRa-primary sensor node. It is intentionally not the production runtime.
//
// RP2040 RTC alarms do not have a dormant-wake route. This target instead uses
// a hardware timer IRQ with clk_ref/clk_sys running from ROSC while XOSC is
// disabled. It is an internal timed sleep proof, not true XOSC dormant mode.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/sync.h"
#include "hardware/xosc.h"
#include "pico/stdlib.h"

#include "config.h"
#include "lora_protocol.h"
#include "lora_transport.h"
#include "sensors.h"

#if !PICO_RP2040
#error "pico_w_sensor_node_lora_low_power is an RP2040/Pico W feasibility target"
#endif

enum {
    LOW_POWER_WAKE_INTERVAL_SECONDS = 5,
    LOW_POWER_USB_OBSERVATION_DELAY_MS = 3000,
    LOW_POWER_USB_REENUMERATION_DELAY_MS = 3000,
    LOW_POWER_ACTIVE_OBSERVATION_DELAY_MS = 1000,
    LOW_POWER_WAKE_MARKER_GPIO = 0,
    LOW_POWER_PHASE_PULSE_HIGH_MS = 100,
    LOW_POWER_PHASE_PULSE_LOW_MS = 100,
    LOW_POWER_PHASE_GAP_MS = 300,
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

static void place_lr22_controls_in_safe_state(void) {
    // Between test cycles, documented normal-mode inputs are held low and AUX
    // remains an input so the Pico never drives the module's status output.
    gpio_init(VG_DEFAULT_LORA_M0_GPIO);
    gpio_set_dir(VG_DEFAULT_LORA_M0_GPIO, GPIO_OUT);
    gpio_put(VG_DEFAULT_LORA_M0_GPIO, false);

    gpio_init(VG_DEFAULT_LORA_M1_GPIO);
    gpio_set_dir(VG_DEFAULT_LORA_M1_GPIO, GPIO_OUT);
    gpio_put(VG_DEFAULT_LORA_M1_GPIO, false);

    gpio_init(VG_DEFAULT_LORA_AUX_GPIO);
    gpio_set_dir(VG_DEFAULT_LORA_AUX_GPIO, GPIO_IN);
}

static void init_wake_marker(void) {
    gpio_init(LOW_POWER_WAKE_MARKER_GPIO);
    gpio_set_dir(LOW_POWER_WAKE_MARKER_GPIO, GPIO_OUT);
    gpio_put(LOW_POWER_WAKE_MARKER_GPIO, false);
}

static void emit_phase_marker(uint32_t wake_counter, uint8_t phase, const char *name) {
    for (uint8_t pulse = 0; pulse < phase; ++pulse) {
        gpio_put(LOW_POWER_WAKE_MARKER_GPIO, true);
        sleep_ms(LOW_POWER_PHASE_PULSE_HIGH_MS);
        gpio_put(LOW_POWER_WAKE_MARKER_GPIO, false);
        if (pulse + 1u < phase) {
            sleep_ms(LOW_POWER_PHASE_PULSE_LOW_MS);
        }
    }
    sleep_ms(LOW_POWER_PHASE_GAP_MS);
    printf("[low-power] cycle=%lu phase=%u %s\n",
           (unsigned long)wake_counter, (unsigned)phase, name);
}

static void emit_wake_phase_marker(uint32_t wake_counter) {
    // USB CDC is restored after the clock transition. Give the host a bounded
    // re-enumeration window before emitting the next cycle's serial markers.
    gpio_put(LOW_POWER_WAKE_MARKER_GPIO, false);
    sleep_ms(LOW_POWER_USB_REENUMERATION_DELAY_MS);
    emit_phase_marker(wake_counter, 1, "wake=timer-success");
}

static bool measure_rosc_and_save_clock_rates(void) {
    uint32_t rosc_khz = frequency_count_khz(CLOCKS_FC0_SRC_VALUE_ROSC_CLKSRC);
    if (rosc_khz == 0) {
        return false;
    }
    g_rosc_hz = rosc_khz * KHZ;
    g_sys_hz = clock_get_hz(clk_sys);
    g_usb_hz = clock_get_hz(clk_usb);
    return g_sys_hz != 0 && g_usb_hz != 0;
}

static bool timer_rosc_sleep(uint32_t wake_counter) {
    g_timer_alarm_fired = false;
    gpio_put(LOW_POWER_WAKE_MARKER_GPIO, false);
    if (add_alarm_in_ms(LOW_POWER_WAKE_INTERVAL_SECONDS * 1000,
                        timer_alarm_handler, NULL, true) < 0) {
        printf("[low-power] cycle=%lu error=timer-alarm-setup-failed\n", (unsigned long)wake_counter);
        return false;
    }
    printf("[low-power] cycle=%lu state=rosc-sleep-armed wake_in=%us\n",
           (unsigned long)wake_counter,
           LOW_POWER_WAKE_INTERVAL_SECONDS);
    stdio_flush();
    // Keep a short awake interval only so USB CDC can deliver the marker
    // around the clock transition. It is not the sleep implementation.
    sleep_ms(LOW_POWER_ACTIVE_OBSERVATION_DELAY_MS);

    // The timer is clocked from clk_ref. Move both core and reference clocks
    // to ROSC before stopping XOSC; WFI then wakes on the timer IRQ.
    clock_configure_undivided(clk_ref,
                              CLOCKS_CLK_REF_CTRL_SRC_VALUE_ROSC_CLKSRC_PH,
                              0, g_rosc_hz);
    clock_configure_undivided(clk_sys,
                              CLOCKS_CLK_SYS_CTRL_SRC_VALUE_CLKSRC_CLK_SYS_AUX,
                              CLOCKS_CLK_SYS_CTRL_AUXSRC_VALUE_ROSC_CLKSRC,
                              g_rosc_hz);
    xosc_disable();
    while (!g_timer_alarm_fired) {
        __wfi();
    }
    gpio_put(LOW_POWER_WAKE_MARKER_GPIO, true);
    xosc_init();
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

    emit_wake_phase_marker(wake_counter);

    printf("[low-power] cycle=%lu state=woke timer_alarm=%s\n",
           (unsigned long)wake_counter,
           g_timer_alarm_fired ? "true" : "false");
    stdio_flush();
    sleep_ms(LOW_POWER_ACTIVE_OBSERVATION_DELAY_MS);
    return g_timer_alarm_fired;
}

static void run_active_cycle(const node_config_t *config, uint32_t wake_counter) {
    sensor_snapshot_t snapshot = {0};
    lora_transport_t radio;
    lora_transport_config_t radio_config = lora_transport_default_config();
    char frame[VG_LORA_MAX_FRAME_SIZE + 1u] = {0};

    printf("[low-power] cycle=%lu sensor=init ads1115 channel=0\n", (unsigned long)wake_counter);
    sensors_init(config);
    snapshot.soil_moisture_read = sensors_read(config, 0, &snapshot);
    if (!snapshot.soil_moisture_read) {
        printf("[low-power] cycle=%lu sensor=read-failed\n", (unsigned long)wake_counter);
        return;
    }
    emit_phase_marker(wake_counter, 2, "ads1115=read-success");
    printf("[low-power] cycle=%lu i2c=initialized ads1115=detected channel=0 raw=%u percent=%d plausible=%s\n",
           (unsigned long)wake_counter,
           (unsigned)snapshot.moisture_raw,
           snapshot.moisture_percent,
           snapshot.healthy ? "true" : "outside-calibration-window");
    if (!lora_transport_init(&radio, &radio_config)) {
        printf("[low-power] cycle=%lu lora=init-failed\n", (unsigned long)wake_counter);
        return;
    }
    emit_phase_marker(wake_counter, 3, "lr22-uart=initialized");
    bool formatted = lora_format_autonomous_channel_state_frame(
        frame, sizeof(frame), config, &snapshot, 0, "scheduled", wake_counter,
        to_ms_since_boot(get_absolute_time()) / 1000u);
    if (!formatted) {
        printf("[low-power] cycle=%lu frame=format-failed\n", (unsigned long)wake_counter);
        uart_deinit(radio_config.uart);
        place_lr22_controls_in_safe_state();
        return;
    }

    size_t frame_length = strlen(frame);
    printf("[low-power] cycle=%lu frame=format-success bytes=%u\n",
           (unsigned long)wake_counter, (unsigned)frame_length);
    emit_phase_marker(wake_counter, 4, "frame=handed-to-transmit");
    printf("[low-power] cycle=%lu uart=write-attempt gpio=%u bytes=%u\n",
           (unsigned long)wake_counter,
           (unsigned)radio_config.tx_gpio,
           (unsigned)frame_length);
    bool sent = lora_transport_send_frame(&radio, frame, frame_length);
    if (sent) {
        // The transport function guarantees bytes reached the UART FIFO, not
        // that the final byte left the shift register. Drain before deinit so
        // this target never relies on UART teardown timing for a frame.
        uart_tx_wait_blocking(radio_config.uart);
        emit_phase_marker(wake_counter, 5, "transmit=returned-success uart=drained");
    } else {
        printf("[low-power] cycle=%lu transmit=returned-failure\n", (unsigned long)wake_counter);
    }
    uart_deinit(radio_config.uart);
    place_lr22_controls_in_safe_state();
    if (sent) {
        emit_phase_marker(wake_counter, 6, "cycle=complete peripherals=inactive");
    }
}

int main(void) {
    stdio_init_all();
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    sleep_ms(LOW_POWER_USB_OBSERVATION_DELAY_MS);

    printf("[low-power] boot target=lora-primary-feasibility cyw43=not-linked\n");
    place_lr22_controls_in_safe_state();
    init_wake_marker();
    node_config_t config;
    node_config_load(&config);

    if (!measure_rosc_and_save_clock_rates()) {
        printf("[low-power] fatal=rosc-clock-measurement-failed\n");
        while (true) {
            tight_loop_contents();
        }
    }

    for (uint32_t wake_counter = 1;; ++wake_counter) {
        printf("[low-power] cycle=%lu state=awake lr22=controls-safe\n",
               (unsigned long)wake_counter);
        stdio_flush();
        run_active_cycle(&config, wake_counter);

        if (!timer_rosc_sleep(wake_counter)) {
            printf("[low-power] fatal=unexpected-wake-source cycle=%lu\n",
                   (unsigned long)wake_counter);
            while (true) {
                tight_loop_contents();
            }
        }
    }
}
