#include "dedicated_actuator_journal_boot.h"

#include <string.h>

#include "actuator_flash_mutation_policy.h"
#include "hardware/sync.h"
#include "hardware/watchdog.h"

static bool read_only_page(
    void *context,
    size_t bank,
    size_t page,
    uint8_t output[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
) {
    vg_dedicated_actuator_journal_boot_t *boot = context;
    const bool read = boot && boot->physical_backend.read_page &&
                      boot->physical_backend.read_page(
                          boot->physical_backend.context, bank, page, output
                      );
    if (!read && boot) {
        // Preserve this across subsequent successful reads in the other bank.
        boot->backend_read_failed = true;
    }
    return read;
}

static bool mutation_is_allowed(
    vg_dedicated_actuator_journal_boot_t *boot,
    vg_actuator_flash_mutation_t mutation
) {
    // Missing runtime authority fails closed. The normal boot call supplies
    // mqtt_node_any_actuator_output_active after relay safe-off and runtime
    // initialization have established every run slot as inactive.
    const bool any_output_active = !boot || !boot->any_output_active ||
                                   boot->any_output_active(boot->any_output_active_context);
    const vg_actuator_flash_mutation_decision_t decision =
        vg_actuator_flash_mutation_policy_decide(mutation, any_output_active);
    if (decision != VG_ACTUATOR_FLASH_MUTATION_ALLOWED && boot) {
        boot->maintenance_policy_denied = true;
    }
    return decision == VG_ACTUATOR_FLASH_MUTATION_ALLOWED;
}

static bool program_page_if_idle(
    void *context,
    size_t bank,
    size_t page,
    const uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
) {
    vg_dedicated_actuator_journal_boot_t *boot = context;
    if (!mutation_is_allowed(boot, VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM)) {
        return false;
    }
    const bool programmed = boot->physical_backend.program_page &&
                            boot->physical_backend.program_page(
                                boot->physical_backend.context, bank, page, bytes
                            );
    // At most one header program occurs in Step 50, but keep the watchdog
    // serviced between every bounded physical mutation rather than disabling
    // it across maintenance.
    watchdog_update();
    return programmed;
}

static bool erase_sector_if_idle(void *context, size_t bank, size_t sector) {
    vg_dedicated_actuator_journal_boot_t *boot = context;
    if (!mutation_is_allowed(boot, VG_ACTUATOR_FLASH_MUTATION_JOURNAL_SECTOR_ERASE)) {
        return false;
    }
    const bool erased = boot->physical_backend.erase_sector &&
                         boot->physical_backend.erase_sector(
                             boot->physical_backend.context, bank, sector
                         );
    // Cleanup can erase three sectors; service the existing watchdog after
    // each one. This makes no claim about hardware flash timing.
    watchdog_update();
    return erased;
}

static void open_and_map(vg_dedicated_actuator_journal_boot_t *boot) {
    const vg_actuator_start_journal_storage_backend_t backend = {
        .context = boot,
        .read_page = read_only_page,
        .program_page = program_page_if_idle,
        .erase_sector = erase_sector_if_idle,
    };
    (void)vg_actuator_start_journal_storage_open(&boot->storage, &backend);
    vg_dedicated_actuator_journal_runtime_state_from_storage(
        &boot->runtime,
        &boot->storage,
        boot->backend_read_failed
    );
}

void vg_dedicated_actuator_journal_boot_load(vg_dedicated_actuator_journal_boot_t *boot) {
    if (!boot) {
        return;
    }

    memset(boot, 0, sizeof(*boot));
    // This initializes only adapter RAM bookkeeping; it performs no flash I/O.
    vg_pico_actuator_journal_flash_init(&boot->physical_flash);
    boot->physical_backend = vg_pico_actuator_journal_flash_backend(&boot->physical_flash);

    open_and_map(boot);
}

void vg_dedicated_actuator_journal_boot_maintain(
    vg_dedicated_actuator_journal_boot_t *boot,
    vg_dedicated_actuator_any_output_active_fn any_output_active,
    void *any_output_active_context
) {
    if (!boot) {
        return;
    }

    boot->any_output_active = any_output_active;
    boot->any_output_active_context = any_output_active_context;
    boot->maintenance_policy_denied = false;
    memset(&boot->maintenance, 0, sizeof(boot->maintenance));
    boot->maintenance.action = VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE;
    boot->maintenance.storage_result = VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_READY;
    boot->maintenance.final_state = boot->storage.state;

    const vg_dedicated_actuator_journal_maintenance_action_t action =
        vg_dedicated_actuator_journal_maintenance_action_for_health(boot->runtime.health);
    vg_actuator_flash_mutation_t required_mutation;
    if (action == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK) {
        required_mutation = VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM;
    } else if (action == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE) {
        required_mutation = VG_ACTUATOR_FLASH_MUTATION_JOURNAL_SECTOR_ERASE;
    } else {
        boot->maintenance.storage_result = VG_ACTUATOR_START_JOURNAL_STORAGE_OK;
        return;
    }

    // Preflight avoids entering shared mutation code when the policy already
    // knows it must deny. The guarded backend checks again before every real
    // program/erase request.
    if (!mutation_is_allowed(boot, required_mutation)) {
        return;
    }

    vg_dedicated_actuator_journal_maintenance_run(&boot->storage, &boot->maintenance);
    // maintenance_run rescans after every attempted mutation. Map that fresh
    // durable state rather than deriving health from the operation result.
    vg_dedicated_actuator_journal_runtime_state_from_storage(
        &boot->runtime,
        &boot->storage,
        boot->backend_read_failed
    );
}

vg_dedicated_actuator_journal_persistence_result_t
vg_dedicated_actuator_journal_boot_start_append_preflight(
    const vg_dedicated_actuator_journal_boot_t *boot
) {
    const bool any_output_active = !boot || !boot->any_output_active ||
                                   boot->any_output_active(boot->any_output_active_context);
    return vg_dedicated_actuator_journal_persistence_preflight(
        boot ? &boot->runtime : NULL,
        any_output_active
    );
}

vg_dedicated_actuator_journal_persistence_result_t
vg_dedicated_actuator_journal_boot_append_prepared_start(
    vg_dedicated_actuator_journal_boot_t *boot,
    const vg_actuator_start_journal_candidate_t *candidate,
    uint64_t *sequence_out
) {
    if (!boot) {
        return VG_DEDICATED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE;
    }

    // MQTT command callbacks are serialized on one core, but they may be
    // delivered from the background networking context. Keep the final
    // all-output-idle check and the one-page append in the same interrupt
    // exclusion region, matching the existing config-save mutation boundary:
    // another START cannot energize a line between this check and program.
    const uint32_t interrupt_state = save_and_disable_interrupts();
    const bool any_output_active = !boot->any_output_active ||
                                   boot->any_output_active(boot->any_output_active_context);
    const vg_dedicated_actuator_journal_persistence_result_t result =
        vg_dedicated_actuator_journal_persistence_append_prepared(
        &boot->storage,
        &boot->runtime,
        &boot->backend_read_failed,
        any_output_active,
        candidate,
        sequence_out
    );
    restore_interrupts(interrupt_state);
    return result;
}

vg_dedicated_actuator_journal_reclaim_result_t
vg_dedicated_actuator_journal_boot_reclaim_full_start(
    vg_dedicated_actuator_journal_boot_t *boot,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time
) {
    if (!boot) {
        return VG_DEDICATED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
    }

    // Compaction can erase/program multiple pages. Hold the same interrupt
    // fence used for the final append check so no START can energize an output
    // between the idle decision and any destructive mutation. The guarded
    // backend also checks the authoritative predicate before every mutation.
    const uint32_t interrupt_state = save_and_disable_interrupts();
    const bool any_output_active = !boot->any_output_active ||
                                   boot->any_output_active(boot->any_output_active_context);
    const vg_dedicated_actuator_journal_reclaim_result_t result =
        vg_dedicated_actuator_journal_persistence_reclaim_full(
            &boot->storage,
            &boot->runtime,
            &boot->backend_read_failed,
            any_output_active,
            trusted_now_epoch_seconds,
            trusted_time,
            boot->retained_snapshot,
            VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT
        );
    restore_interrupts(interrupt_state);
    return result;
}
