// RP2040 LoRa-primary software baseline with a combined, scheduler-driven
// SHT40 and configured-channel ADS1115 acquisition cycle.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "hardware/gpio.h"
#include "hardware/watchdog.h"
#include "pico/stdlib.h"

#include "config.h"
#include "lora_command_runtime.h"
#include "lora_low_power_platform.h"
#include "lora_protocol.h"
#include "lora_scheduler.h"
#include "lora_scheduled_acquisition.h"
#include "lora_transport.h"

#if !PICO_RP2040
#error "pico_w_sensor_node_lora_low_power supports only RP2040/Pico W"
#endif

enum {
    LOW_POWER_USB_OBSERVATION_DELAY_MS = 3000,
    LOW_POWER_WAKE_MARKER_GPIO = 0,
    LOW_POWER_PHASE_PULSE_HIGH_MS = 100,
    LOW_POWER_PHASE_PULSE_LOW_MS = 100,
    LOW_POWER_PHASE_GAP_MS = 300,
};

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

static void fail_safe_reset(void) {
    place_lr22_controls_in_safe_state();
    stdio_flush();
    watchdog_reboot(0u, 0u, 0u);
    while (true) {
        tight_loop_contents();
    }
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

static void run_combined_sensing_cycle(
    const node_config_t *config,
    uint32_t wake_counter,
    float air_temperature_c,
    float humidity_percent,
    bool environment_valid
) {
    lora_soil_channel_result_t results[VG_ADS1115_CHANNEL_COUNT];
    lora_transport_t radio;
    lora_transport_config_t radio_config = lora_transport_default_config();
    uint8_t successful_reads = 0u;
    uint8_t configured_channels = 0u;

    lora_acquire_soil_channels(
        config,
        air_temperature_c,
        humidity_percent,
        environment_valid,
        results
    );
    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT; ++channel) {
        const lora_soil_channel_result_t *result = &results[channel];
        if (!result->configured) {
            continue;
        }
        configured_channels++;
        printf("[low-power] cycle=%lu soil channel=%u attempted=%s success=%s\n",
               (unsigned long)wake_counter,
               (unsigned)channel,
               result->attempted ? "true" : "false",
               result->read_succeeded ? "true" : "false");
        if (result->read_succeeded) {
            successful_reads++;
            emit_phase_marker(wake_counter, 2, "ads1115=channel-read-success");
        }
    }

    if (successful_reads == 0u) {
        printf("[low-power] cycle=%lu soil configured=%u successful=0 telemetry=none\n",
               (unsigned long)wake_counter,
               (unsigned)configured_channels);
        return;
    }
    if (!lora_transport_init(&radio, &radio_config)) {
        printf("[low-power] cycle=%lu lora=init-failed\n", (unsigned long)wake_counter);
        return;
    }
    emit_phase_marker(wake_counter, 3, "lr22-uart=initialized");

    bool transport_available = true;
    uint8_t frames_sent = 0u;
    for (uint8_t channel = 0; channel < VG_ADS1115_CHANNEL_COUNT && transport_available; ++channel) {
        const lora_soil_channel_result_t *result = &results[channel];
        if (!result->read_succeeded) {
            continue;
        }

        char frame[VG_LORA_MAX_FRAME_SIZE + 1u] = {0};
        const bool formatted = lora_format_autonomous_channel_state_frame(
            frame,
            sizeof(frame),
            config,
            &result->snapshot,
            channel,
            "scheduled",
            wake_counter,
            lora_low_power_platform_monotonic_ms() / 1000u
        );
        if (!formatted) {
            printf("[low-power] cycle=%lu frame=format-failed channel=%u\n",
                   (unsigned long)wake_counter,
                   (unsigned)channel);
            continue;
        }

        const size_t frame_length = strlen(frame);
        emit_phase_marker(wake_counter, 4, "frame=handed-to-transmit");
        if (!lora_transport_send_frame(&radio, frame, frame_length)) {
            transport_available = false;
            printf("[low-power] cycle=%lu transmit=failed channel=%u; skipping remaining telemetry\n",
                   (unsigned long)wake_counter,
                   (unsigned)channel);
            continue;
        }
        // Drain with the transport deadline before teardown so each completed
        // frame has left the UART shift register.
        if (!lora_transport_drain(&radio)) {
            transport_available = false;
            printf("[low-power] cycle=%lu transmit=drain-timeout channel=%u\n",
                   (unsigned long)wake_counter,
                   (unsigned)channel);
            continue;
        }
        frames_sent++;
        emit_phase_marker(wake_counter, 5, "transmit=returned-success uart=drained");
    }
    uart_deinit(radio_config.uart);
    place_lr22_controls_in_safe_state();
    emit_phase_marker(wake_counter, 6, "combined-cycle=complete radio=inactive");
    printf("[low-power] cycle=%lu combined configured=%u successful=%u frames_sent=%u environment_fresh=%s\n",
           (unsigned long)wake_counter,
           (unsigned)configured_channels,
           (unsigned)successful_reads,
           (unsigned)frames_sent,
           environment_valid ? "true" : "false");
}

int main(void) {
    stdio_init_all();
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    sleep_ms(LOW_POWER_USB_OBSERVATION_DELAY_MS);

    printf("[low-power] boot target=lora-primary-combined-schedule cyw43=not-linked\n");
    place_lr22_controls_in_safe_state();
    init_wake_marker();
    node_config_t config;
    node_config_load(&config);

    if (!lora_low_power_platform_init()) {
        printf("[low-power] fatal=rosc-clock-measurement-failed\n");
        fail_safe_reset();
    }

    lora_scheduler_t scheduler;
    const uint32_t boot_monotonic_ms = lora_low_power_platform_monotonic_ms();
    const lora_scheduler_config_t scheduler_config = lora_scheduler_default_config();
    if (!lora_scheduler_init(&scheduler, &scheduler_config, boot_monotonic_ms)) {
        printf("[low-power] fatal=scheduler-init-failed\n");
        fail_safe_reset();
    }

    // These persist across bounded wake cycles so a retry with the same
    // correlation tuple is deduplicated while the firmware remains powered.
    lora_frame_buffer_t lora_rx_buffer;
    lora_frame_buffer_reset(&lora_rx_buffer);
    lora_recent_command_t lora_recent_commands[VG_LORA_RECENT_COMMAND_COUNT] = {0};
    size_t lora_next_recent_command = 0u;

    for (uint32_t wake_counter = 1;; ++wake_counter) {
        const uint32_t monotonic_ms = lora_low_power_platform_monotonic_ms();
        const lora_wall_clock_t wall_clock = lora_low_power_platform_wall_clock();
        const lora_scheduler_plan_t plan = lora_scheduler_plan(&scheduler, monotonic_ms, &wall_clock);
        printf("[low-power] cycle=%lu state=awake wall_clock_valid=%s active=%s combined_due=%s\n",
               (unsigned long)wake_counter,
               plan.wall_clock_valid ? "true" : "false",
               plan.active_window ? "true" : "false",
               plan.combined_due ? "true" : "false");
        stdio_flush();

        float air_temperature_c = 0.0f;
        float humidity_percent = 0.0f;
        bool environment_valid = false;
        bool environment_attempted = false;
        bool soil_sensors_initialized = false;
        if (plan.combined_due) {
            environment_attempted = true;
            environment_valid = lora_acquire_environment(
                &config,
                &air_temperature_c,
                &humidity_percent
            );
            printf("[low-power] cycle=%lu environment attempted=true success=%s\n",
                   (unsigned long)wake_counter,
                   environment_valid ? "true" : "false");
            run_combined_sensing_cycle(
                &config,
                wake_counter,
                air_temperature_c,
                humidity_percent,
                environment_valid
            );
            soil_sensors_initialized = true;
            // One SHT40 attempt and the all-channel soil attempt set are
            // bounded. The single cadence deadline advances even if either
            // sensor class or telemetry sends fail.
            lora_scheduler_mark_combined_complete(
                &scheduler,
                lora_low_power_platform_monotonic_ms()
            );
        }

        // Keep one short, bounded receive opportunity on every wake. This is
        // deliberately independent of scheduled telemetry: a command cannot
        // alter scheduler cadence, and a scheduled transmit failure does not
        // suppress the next gateway retry opportunity.
        lora_transport_t command_radio;
        const lora_transport_config_t command_radio_config = lora_transport_default_config();
        lora_pending_command_t pending_command = {0};
        lora_command_window_stats_t command_stats = {0};
        if (lora_transport_init(&command_radio, &command_radio_config)) {
            printf("[low-power] cycle=%lu command-window=open duration_ms=%lu\n",
                   (unsigned long)wake_counter,
                   (unsigned long)VG_LORA_COMMAND_INTAKE_WINDOW_MS);
            service_lora_command_window(
                &command_radio,
                &lora_rx_buffer,
                &config,
                VG_LORA_COMMAND_INTAKE_WINDOW_MS,
                &pending_command,
                lora_recent_commands,
                VG_LORA_RECENT_COMMAND_COUNT,
                &command_stats
            );

            if (pending_command.type != LORA_PENDING_COMMAND_NONE) {
                // Match the established request_reading result behavior: use
                // this wake's environmental sample when available, otherwise
                // take one bounded SHT40 sample for the accepted request.
                if (!environment_attempted) {
                    environment_attempted = true;
                    environment_valid = lora_acquire_environment(
                        &config,
                        &air_temperature_c,
                        &humidity_percent
                    );
                    printf("[low-power] cycle=%lu command-environment attempted=true success=%s\n",
                           (unsigned long)wake_counter,
                           environment_valid ? "true" : "false");
                }
                handle_pending_lora_command(
                    &command_radio,
                    &config,
                    &pending_command,
                    lora_recent_commands,
                    VG_LORA_RECENT_COMMAND_COUNT,
                    &lora_next_recent_command,
                    air_temperature_c,
                    humidity_percent,
                    environment_valid,
                    NULL,
                    &soil_sensors_initialized,
                    &command_stats
                );
            }
            log_lora_command_window_summary(&command_stats);
            if (!lora_transport_drain(&command_radio)) {
                printf("[low-power] cycle=%lu command-window=drain-timeout\n",
                       (unsigned long)wake_counter);
            }
            uart_deinit(command_radio_config.uart);
        } else {
            printf("[low-power] cycle=%lu command-window=radio-init-failed\n",
                   (unsigned long)wake_counter);
        }
        place_lr22_controls_in_safe_state();

        const lora_scheduler_plan_t sleep_plan = lora_scheduler_plan(
            &scheduler,
            lora_low_power_platform_monotonic_ms(),
            &wall_clock
        );
        printf("[low-power] cycle=%lu state=rosc-sleep-armed wake_in_ms=%lu\n",
               (unsigned long)wake_counter,
               (unsigned long)sleep_plan.next_wake_delay_ms);
        stdio_flush();
        if (!lora_low_power_platform_sleep_ms(sleep_plan.next_wake_delay_ms)) {
            printf("[low-power] fatal=sleep-setup-failed cycle=%lu\n",
                   (unsigned long)wake_counter);
            fail_safe_reset();
        }
    }
}
