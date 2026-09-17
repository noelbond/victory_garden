#include "combined_actuator_journal_boot.h"

#include <string.h>

#include "actuator_flash_mutation_policy.h"
#include "hardware/watchdog.h"
#include "hardware/sync.h"

static bool read_page(void *context, size_t bank, size_t page,
                      uint8_t out[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    vg_combined_actuator_journal_boot_t *boot = context;
    const bool ok = boot && boot->physical_backend.read_page &&
                    boot->physical_backend.read_page(boot->physical_backend.context, bank, page, out);
    if (!ok && boot) boot->backend_read_failed = true;
    return ok;
}

static bool mutation_allowed(vg_combined_actuator_journal_boot_t *boot,
                             vg_actuator_flash_mutation_t mutation) {
    const bool active = !boot || !boot->any_output_active ||
                        boot->any_output_active(boot->any_output_active_context);
    const bool allowed = vg_actuator_flash_mutation_policy_decide(mutation, active) ==
                         VG_ACTUATOR_FLASH_MUTATION_ALLOWED;
    if (!allowed && boot) boot->maintenance_policy_denied = true;
    return allowed;
}

static bool program_page(void *context, size_t bank, size_t page,
                         const uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    vg_combined_actuator_journal_boot_t *boot = context;
    if (!mutation_allowed(boot, VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM)) return false;
    const bool ok = boot->physical_backend.program_page &&
                    boot->physical_backend.program_page(boot->physical_backend.context, bank, page, bytes);
    watchdog_update();
    return ok;
}

static bool erase_sector(void *context, size_t bank, size_t sector) {
    vg_combined_actuator_journal_boot_t *boot = context;
    if (!mutation_allowed(boot, VG_ACTUATOR_FLASH_MUTATION_JOURNAL_SECTOR_ERASE)) return false;
    const bool ok = boot->physical_backend.erase_sector &&
                    boot->physical_backend.erase_sector(boot->physical_backend.context, bank, sector);
    watchdog_update();
    return ok;
}

static void open_and_map(vg_combined_actuator_journal_boot_t *boot) {
    const vg_actuator_start_journal_storage_backend_t backend = {
        .context = boot, .read_page = read_page, .program_page = program_page, .erase_sector = erase_sector,
    };
    (void)vg_actuator_start_journal_storage_open(&boot->storage, &backend);
    vg_combined_actuator_journal_runtime_state_from_storage(
        &boot->runtime, &boot->storage, boot->backend_read_failed);
}

void vg_combined_actuator_journal_boot_load(vg_combined_actuator_journal_boot_t *boot) {
    if (!boot) return;
    memset(boot, 0, sizeof(*boot));
    vg_pico_actuator_journal_flash_init(&boot->physical_flash);
    boot->physical_backend = vg_pico_actuator_journal_flash_backend(&boot->physical_flash);
    open_and_map(boot);
}

void vg_combined_actuator_journal_boot_maintain(
    vg_combined_actuator_journal_boot_t *boot,
    vg_combined_actuator_any_output_active_fn any_output_active,
    void *any_output_active_context
) {
    if (!boot) return;
    boot->any_output_active = any_output_active;
    boot->any_output_active_context = any_output_active_context;
    boot->maintenance_policy_denied = false;
    const vg_combined_actuator_journal_maintenance_action_t action =
        vg_combined_actuator_journal_maintenance_action_for_health(boot->runtime.health);
    if (action == VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_NONE) {
        memset(&boot->maintenance, 0, sizeof(boot->maintenance));
        boot->maintenance.storage_result = VG_ACTUATOR_START_JOURNAL_STORAGE_OK;
        boot->maintenance.final_state = boot->storage.state;
        return;
    }
    const vg_actuator_flash_mutation_t mutation =
        action == VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK
            ? VG_ACTUATOR_FLASH_MUTATION_JOURNAL_PAGE_PROGRAM
            : VG_ACTUATOR_FLASH_MUTATION_JOURNAL_SECTOR_ERASE;
    if (!mutation_allowed(boot, mutation)) return;
    vg_combined_actuator_journal_maintenance_run(&boot->storage, &boot->maintenance);
    vg_combined_actuator_journal_runtime_state_from_storage(
        &boot->runtime, &boot->storage, boot->backend_read_failed);
}

vg_combined_actuator_journal_persistence_result_t
vg_combined_actuator_journal_boot_append_prepared_start(
    vg_combined_actuator_journal_boot_t *boot,
    const vg_actuator_start_journal_candidate_t *candidate, uint64_t *sequence_out) {
    if (!boot) return VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE;
    const uint32_t irq = save_and_disable_interrupts();
    const bool active = !boot->any_output_active || boot->any_output_active(boot->any_output_active_context);
    const vg_combined_actuator_journal_persistence_result_t result =
        vg_combined_actuator_journal_persistence_append_prepared(
            &boot->storage, &boot->runtime, &boot->backend_read_failed, active, candidate, sequence_out);
    restore_interrupts(irq);
    return result;
}
vg_combined_actuator_journal_reclaim_result_t vg_combined_actuator_journal_boot_reclaim_full_start(
    vg_combined_actuator_journal_boot_t *boot, int64_t now, bool trusted_time) {
    if (!boot) return VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_UNAVAILABLE;
    const uint32_t irq = save_and_disable_interrupts();
    const bool active = !boot->any_output_active || boot->any_output_active(boot->any_output_active_context);
    const vg_combined_actuator_journal_reclaim_result_t result =
        vg_combined_actuator_journal_persistence_reclaim_full(
            &boot->storage, &boot->runtime, &boot->backend_read_failed, active, now, trusted_time,
            boot->retained_snapshot, VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT);
    restore_interrupts(irq);
    return result;
}
