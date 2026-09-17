#include <assert.h>
#include <string.h>

#include "combined_actuator_journal_maintenance.h"
#include "simulated_flash_backend.h"

#define HEADER_LAYOUT_VERSION_OFFSET 4u
#define CRC_OFFSET 248u
#define CRC_INVERSE_OFFSET 252u

static void write_u32_le(uint8_t *bytes, uint32_t value) {
    for (size_t index = 0u; index < 4u; ++index) bytes[index] = (uint8_t)(value >> (index * 8u));
}

static void refresh_integrity(uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    const uint32_t crc = vg_actuator_start_journal_flash_crc32(page, CRC_OFFSET);
    write_u32_le(page + CRC_OFFSET, crc);
    write_u32_le(page + CRC_INVERSE_OFFSET, ~crc);
}

static vg_actuator_start_journal_storage_state_t open_storage(
    vg_simulated_flash_backend_t *flash, vg_actuator_start_journal_storage_t *storage) {
    const vg_actuator_start_journal_storage_backend_t backend = vg_simulated_flash_backend_interface(flash);
    return vg_actuator_start_journal_storage_open(storage, &backend);
}

static void initialize(vg_simulated_flash_backend_t *flash, vg_actuator_start_journal_storage_t *storage) {
    assert(open_storage(flash, storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
    assert(vg_actuator_start_journal_storage_initialize(storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
}

static vg_actuator_start_journal_record_t record(void) {
    vg_actuator_start_journal_record_t value = { .accepted = true,
        .version = VG_ACTUATOR_START_JOURNAL_RECORD_VERSION, .irrigation_line = 1u,
        .issued_at_epoch_seconds = 1700000000 };
    strcpy(value.idempotency_key, "accepted-key");
    strcpy(value.zone_id, "zone1");
    strcpy(value.node_id, "node1");
    return value;
}

static void test_blank_and_healthy_history(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_combined_actuator_journal_maintenance_result_t result;
    vg_simulated_flash_backend_init(&flash);
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
    vg_combined_actuator_journal_maintenance_run(&storage, &result);
    assert(result.action == VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK);
    assert(result.final_state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
    assert(storage.authoritative_bank == 0u && storage.header.generation == 1u);
    flash.trace_count = 0u;
    vg_combined_actuator_journal_maintenance_run(&storage, &result);
    assert(!result.mutation_attempted && flash.trace_count == 0u);
    uint64_t sequence = 0u;
    const vg_actuator_start_journal_record_t accepted = record();
    assert(vg_actuator_start_journal_storage_append_verified(&storage, &accepted, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    flash.trace_count = 0u;
    vg_combined_actuator_journal_maintenance_run(&storage, &result);
    assert(!result.mutation_attempted && flash.trace_count == 0u);
    assert(storage.record_count == 1u && storage.current_high_water == sequence);
}

static void test_cleanup_and_failure_preserve_authority(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_combined_actuator_journal_maintenance_result_t result;
    vg_simulated_flash_backend_init(&flash); initialize(&flash, &storage);
    uint64_t sequence = 0u; const vg_actuator_start_journal_record_t accepted = record();
    assert(vg_actuator_start_journal_storage_append_verified(&storage, &accepted, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    flash.bytes[1u][0u][0u] = 0u;
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    vg_combined_actuator_journal_maintenance_run(&storage, &result);
    assert(result.action == VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE);
    assert(result.final_state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    assert(storage.record_count == 1u && storage.current_high_water == sequence);
    flash.bytes[1u][0u][0u] = 0u;
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    vg_simulated_flash_backend_set_fault(&flash, VG_SIMULATED_FLASH_FAULT_BEFORE_ERASE, 1u, 0u);
    vg_combined_actuator_journal_maintenance_run(&storage, &result);
    assert(result.storage_result == VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
    assert(storage.state == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    assert(storage.record_count == 1u && storage.current_high_water == sequence);
}

static void test_unhealthy_and_torn_initialization_never_assume_blank(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_combined_actuator_journal_maintenance_result_t result;
    vg_simulated_flash_backend_init(&flash);
    flash.bytes[0u][0u][0u] = 0u;
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);
    flash.trace_count = 0u; vg_combined_actuator_journal_maintenance_run(&storage, &result);
    assert(!result.mutation_attempted && flash.trace_count == 0u);
    vg_simulated_flash_backend_init(&flash); initialize(&flash, &storage);
    write_u32_le(flash.bytes[0u][0u] + HEADER_LAYOUT_VERSION_OFFSET, 999u);
    refresh_integrity(flash.bytes[0u][0u]);
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED);
    flash.trace_count = 0u; vg_combined_actuator_journal_maintenance_run(&storage, &result);
    assert(!result.mutation_attempted && flash.trace_count == 0u);
    vg_combined_actuator_journal_runtime_state_t runtime;
    vg_combined_actuator_journal_runtime_state_from_storage(&runtime, &storage, true);
    assert(runtime.health == VG_COMBINED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE);
    assert(vg_combined_actuator_journal_maintenance_action_for_health(runtime.health) ==
           VG_COMBINED_ACTUATOR_JOURNAL_MAINTENANCE_NONE);
    vg_simulated_flash_backend_init(&flash);
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
    vg_simulated_flash_backend_set_fault(&flash, VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM, 1u, 73u);
    vg_combined_actuator_journal_maintenance_run(&storage, &result);
    assert(result.mutation_attempted && result.final_state == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);
}

int main(void) {
    test_blank_and_healthy_history();
    test_cleanup_and_failure_preserve_authority();
    test_unhealthy_and_torn_initialization_never_assume_blank();
    return 0;
}
