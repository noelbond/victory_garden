#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "dedicated_actuator_journal_maintenance.h"
#include "simulated_flash_backend.h"

#define HEADER_LAYOUT_VERSION_OFFSET 4u
#define CRC_OFFSET 248u
#define CRC_INVERSE_OFFSET 252u

static void write_u32_le(uint8_t *bytes, uint32_t value) {
    for (size_t index = 0u; index < 4u; ++index) {
        bytes[index] = (uint8_t)(value >> (index * 8u));
    }
}

static void refresh_integrity(uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    const uint32_t crc = vg_actuator_start_journal_flash_crc32(page, CRC_OFFSET);
    write_u32_le(page + CRC_OFFSET, crc);
    write_u32_le(page + CRC_INVERSE_OFFSET, ~crc);
}

static vg_actuator_start_journal_storage_state_t open_storage(
    vg_simulated_flash_backend_t *flash,
    vg_actuator_start_journal_storage_t *storage
) {
    const vg_actuator_start_journal_storage_backend_t backend =
        vg_simulated_flash_backend_interface(flash);
    return vg_actuator_start_journal_storage_open(storage, &backend);
}

static void initialize_storage(
    vg_simulated_flash_backend_t *flash,
    vg_actuator_start_journal_storage_t *storage
) {
    assert(open_storage(flash, storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
    assert(vg_actuator_start_journal_storage_initialize(storage) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
}

static vg_actuator_start_journal_record_t record_for(unsigned int number) {
    vg_actuator_start_journal_record_t record;
    memset(&record, 0, sizeof(record));
    record.accepted = true;
    record.version = VG_ACTUATOR_START_JOURNAL_RECORD_VERSION;
    record.irrigation_line = 1u;
    record.issued_at_epoch_seconds = 1700000000 + (int64_t)number;
    snprintf(record.idempotency_key, sizeof(record.idempotency_key), "key-%u", number);
    snprintf(record.zone_id, sizeof(record.zone_id), "zone-%u", number);
    snprintf(record.node_id, sizeof(record.node_id), "node-%u", number);
    return record;
}

static void reset_trace(vg_simulated_flash_backend_t *flash) {
    flash->trace_count = 0u;
    flash->matching_mutation_count = 0u;
}

static void test_blank_initializes_and_rescans(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_maintenance_result_t result;
    vg_simulated_flash_backend_init(&flash);
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);

    vg_dedicated_actuator_journal_maintenance_run(&storage, &result);
    assert(result.action == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_INITIALIZE_BLANK);
    assert(result.mutation_attempted);
    assert(result.storage_result == VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(result.final_state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
    assert(storage.state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY);
    assert(storage.authoritative_bank == 0u);
    assert(storage.header.generation == 1u);
    assert(storage.current_high_water == 0u);
    assert(storage.record_count == 0u);
    assert(flash.trace_count == 1u);
    assert(flash.trace[0].operation == VG_SIMULATED_FLASH_TRACE_PROGRAM);
    assert(flash.trace[0].bank == 0u);
    assert(flash.trace[0].index == VG_ACTUATOR_START_JOURNAL_STORAGE_HEADER_PAGE);
}

static void test_healthy_storage_never_mutates(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_maintenance_result_t result;
    vg_simulated_flash_backend_init(&flash);
    initialize_storage(&flash, &storage);
    reset_trace(&flash);

    vg_dedicated_actuator_journal_maintenance_run(&storage, &result);
    assert(result.action == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE);
    assert(!result.mutation_attempted);
    assert(flash.trace_count == 0u);

    const vg_actuator_start_journal_record_t record = record_for(1u);
    uint64_t sequence = 0u;
    assert(vg_actuator_start_journal_storage_append_verified(&storage, &record, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    const size_t prior_count = storage.record_count;
    const uint64_t prior_high_water = storage.current_high_water;
    const size_t prior_bank = storage.authoritative_bank;
    const uint64_t prior_generation = storage.header.generation;
    reset_trace(&flash);

    vg_dedicated_actuator_journal_maintenance_run(&storage, &result);
    assert(result.action == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE);
    assert(!result.mutation_attempted);
    assert(flash.trace_count == 0u);
    assert(storage.record_count == prior_count);
    assert(storage.current_high_water == prior_high_water);
    assert(storage.authoritative_bank == prior_bank);
    assert(storage.header.generation == prior_generation);
    assert(strcmp(storage.records[0].accepted_record.idempotency_key, record.idempotency_key) == 0);
}

static void test_cleanup_preserves_authority_and_history(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_maintenance_result_t result;
    vg_simulated_flash_backend_init(&flash);
    initialize_storage(&flash, &storage);
    const vg_actuator_start_journal_record_t record = record_for(2u);
    uint64_t sequence = 0u;
    assert(vg_actuator_start_journal_storage_append_verified(&storage, &record, &sequence) ==
           VG_ACTUATOR_START_JOURNAL_STORAGE_OK);

    // Inactive bank B is dirty without making a competing valid header.
    flash.bytes[1u][0u][0u] = 0u;
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    const size_t prior_count = storage.record_count;
    const uint64_t prior_high_water = storage.current_high_water;
    const size_t prior_bank = storage.authoritative_bank;
    const uint64_t prior_generation = storage.header.generation;
    reset_trace(&flash);

    vg_dedicated_actuator_journal_maintenance_run(&storage, &result);
    assert(result.action == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_CLEANUP_INACTIVE);
    assert(result.mutation_attempted);
    assert(result.storage_result == VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    assert(result.final_state == VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    assert(storage.authoritative_bank == prior_bank);
    assert(storage.header.generation == prior_generation);
    assert(storage.record_count == prior_count);
    assert(storage.current_high_water == prior_high_water);
    assert(strcmp(storage.records[0].accepted_record.idempotency_key, record.idempotency_key) == 0);
    assert(flash.trace_count == VG_ACTUATOR_START_JOURNAL_STORAGE_SECTORS_PER_BANK);
    for (size_t index = 0u; index < flash.trace_count; ++index) {
        assert(flash.trace[index].operation == VG_SIMULATED_FLASH_TRACE_ERASE);
        assert(flash.trace[index].bank == 1u);
    }
}

static void test_unhealthy_states_never_select_maintenance(void) {
    assert(vg_dedicated_actuator_journal_maintenance_action_for_health(
               VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_CORRUPT
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE);
    assert(vg_dedicated_actuator_journal_maintenance_action_for_health(
               VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_UNSUPPORTED
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE);
    assert(vg_dedicated_actuator_journal_maintenance_action_for_health(
               VG_DEDICATED_ACTUATOR_JOURNAL_HEALTH_BACKEND_FAILURE
           ) == VG_DEDICATED_ACTUATOR_JOURNAL_MAINTENANCE_NONE);

    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_maintenance_result_t result;
    vg_simulated_flash_backend_init(&flash);
    flash.bytes[0u][0u][0u] = 0u;
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);
    reset_trace(&flash);
    vg_dedicated_actuator_journal_maintenance_run(&storage, &result);
    assert(!result.mutation_attempted);
    assert(flash.trace_count == 0u);

    vg_simulated_flash_backend_init(&flash);
    initialize_storage(&flash, &storage);
    write_u32_le(flash.bytes[0u][0u] + HEADER_LAYOUT_VERSION_OFFSET, 999u);
    refresh_integrity(flash.bytes[0u][0u]);
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED);
    reset_trace(&flash);
    vg_dedicated_actuator_journal_maintenance_run(&storage, &result);
    assert(!result.mutation_attempted);
    assert(flash.trace_count == 0u);
}

static void test_failed_maintenance_rescans_without_false_health(void) {
    vg_simulated_flash_backend_t flash;
    vg_actuator_start_journal_storage_t storage;
    vg_dedicated_actuator_journal_maintenance_result_t result;
    vg_simulated_flash_backend_init(&flash);
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
    vg_simulated_flash_backend_set_fault(
        &flash, VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM, 1u, 73u
    );
    vg_dedicated_actuator_journal_maintenance_run(&storage, &result);
    assert(result.mutation_attempted);
    assert(result.storage_result == VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
    assert(result.final_state == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);
    assert(storage.state == VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT);

    vg_simulated_flash_backend_init(&flash);
    initialize_storage(&flash, &storage);
    const vg_actuator_start_journal_record_t retained_record = record_for(3u);
    uint64_t retained_sequence = 0u;
    assert(vg_actuator_start_journal_storage_append_verified(
               &storage, &retained_record, &retained_sequence
           ) == VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    flash.bytes[1u][0u][0u] = 0u;
    assert(open_storage(&flash, &storage) == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    const size_t authority = storage.authoritative_bank;
    const size_t records = storage.record_count;
    const uint64_t high_water = storage.current_high_water;
    vg_simulated_flash_backend_set_fault(
        &flash, VG_SIMULATED_FLASH_FAULT_BEFORE_ERASE, 1u, 0u
    );
    vg_dedicated_actuator_journal_maintenance_run(&storage, &result);
    assert(result.mutation_attempted);
    assert(result.storage_result == VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE);
    assert(result.final_state == VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED);
    assert(storage.authoritative_bank == authority);
    assert(storage.record_count == records);
    assert(storage.current_high_water == high_water);
    assert(strcmp(storage.records[0].accepted_record.idempotency_key,
                  retained_record.idempotency_key) == 0);
}

int main(void) {
    test_blank_initializes_and_rescans();
    test_healthy_storage_never_mutates();
    test_cleanup_preserves_authority_and_history();
    test_unhealthy_states_never_select_maintenance();
    test_failed_maintenance_rescans_without_false_health();
    return 0;
}
