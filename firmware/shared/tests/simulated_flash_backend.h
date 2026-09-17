#pragma once

#include <stddef.h>
#include <stdint.h>

#include "actuator_start_journal_storage.h"

typedef enum {
    VG_SIMULATED_FLASH_TRACE_PROGRAM = 0,
    VG_SIMULATED_FLASH_TRACE_ERASE,
} vg_simulated_flash_trace_operation_t;

typedef struct {
    vg_simulated_flash_trace_operation_t operation;
    size_t bank;
    size_t index;
} vg_simulated_flash_trace_entry_t;

typedef enum {
    VG_SIMULATED_FLASH_FAULT_NONE = 0,
    VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM,
    VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM,
    VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM,
    VG_SIMULATED_FLASH_FAULT_BEFORE_ERASE,
    VG_SIMULATED_FLASH_FAULT_DURING_ERASE,
    VG_SIMULATED_FLASH_FAULT_AFTER_ERASE,
} vg_simulated_flash_fault_t;

#define VG_SIMULATED_FLASH_MAX_TRACE_ENTRIES 256u

typedef struct {
    uint8_t bytes[VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT]
                 [VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK]
                 [VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    vg_simulated_flash_trace_entry_t trace[VG_SIMULATED_FLASH_MAX_TRACE_ENTRIES];
    size_t trace_count;
    vg_simulated_flash_fault_t fault;
    size_t fault_occurrence;
    size_t matching_mutation_count;
    size_t partial_bytes;
} vg_simulated_flash_backend_t;

void vg_simulated_flash_backend_init(vg_simulated_flash_backend_t *flash);
void vg_simulated_flash_backend_set_fault(vg_simulated_flash_backend_t *flash,
                                          vg_simulated_flash_fault_t fault,
                                          size_t occurrence, size_t partial_bytes);
void vg_simulated_flash_backend_clear_fault(vg_simulated_flash_backend_t *flash);
vg_actuator_start_journal_storage_backend_t vg_simulated_flash_backend_interface(
    vg_simulated_flash_backend_t *flash
);

