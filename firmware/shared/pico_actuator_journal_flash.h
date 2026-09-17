#pragma once

#include <stddef.h>
#include <stdint.h>

#include "actuator_start_journal_storage.h"

typedef enum {
    VG_PICO_ACTUATOR_JOURNAL_FLASH_OK = 0,
    VG_PICO_ACTUATOR_JOURNAL_FLASH_INVALID_ARGUMENT,
    VG_PICO_ACTUATOR_JOURNAL_FLASH_OUT_OF_RANGE,
    VG_PICO_ACTUATOR_JOURNAL_FLASH_DESTINATION_NOT_ERASED,
    VG_PICO_ACTUATOR_JOURNAL_FLASH_SAFE_EXECUTE_FAILED,
} vg_pico_actuator_journal_flash_result_t;

// This context records the most recent low-level result for the bool-returning
// storage-manager backend callbacks. Initializing it performs no flash I/O.
typedef struct {
    vg_pico_actuator_journal_flash_result_t last_result;
} vg_pico_actuator_journal_flash_t;

void vg_pico_actuator_journal_flash_init(vg_pico_actuator_journal_flash_t *journal_flash);

// Reads a non-empty range that remains entirely within the selected logical
// journal bank. `bank_offset` is journal-bank-relative, never a raw flash
// address. This adapter has no API for the final configuration sector.
vg_pico_actuator_journal_flash_result_t vg_pico_actuator_journal_flash_read(
    vg_pico_actuator_journal_flash_t *journal_flash,
    size_t bank,
    size_t bank_offset,
    uint8_t *destination,
    size_t length
);

// Programs exactly one erased 256-byte journal page. The adapter copies the
// caller's bytes into SRAM before entering the XIP-off critical section.
vg_pico_actuator_journal_flash_result_t vg_pico_actuator_journal_flash_program_page(
    vg_pico_actuator_journal_flash_t *journal_flash,
    size_t bank,
    size_t page,
    const uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
);

// Erases exactly one 4 KiB journal sector.
vg_pico_actuator_journal_flash_result_t vg_pico_actuator_journal_flash_erase_sector(
    vg_pico_actuator_journal_flash_t *journal_flash,
    size_t bank,
    size_t sector
);

vg_pico_actuator_journal_flash_result_t vg_pico_actuator_journal_flash_last_result(
    const vg_pico_actuator_journal_flash_t *journal_flash
);

// Creates the existing pure storage manager's backend vtable. Creating this
// bridge does not scan, initialize, erase, or program journal flash.
vg_actuator_start_journal_storage_backend_t vg_pico_actuator_journal_flash_backend(
    vg_pico_actuator_journal_flash_t *journal_flash
);
