#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "actuator_start_journal_storage.h"

// Physical-flash-independent journal geometry and translation. Pico-specific
// code supplies its board's PICO_FLASH_SIZE_BYTES to these helpers.
#define VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE \
    (VG_ACTUATOR_START_JOURNAL_STORAGE_SECTORS_PER_BANK * \
     VG_ACTUATOR_START_JOURNAL_STORAGE_SECTOR_SIZE)
#define VG_ACTUATOR_JOURNAL_FLASH_SIZE \
    (VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT * VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE)
#define VG_ACTUATOR_JOURNAL_FLASH_CONFIG_SIZE \
    VG_ACTUATOR_START_JOURNAL_STORAGE_SECTOR_SIZE
#define VG_ACTUATOR_JOURNAL_FLASH_PROTECTED_TAIL_SIZE \
    (VG_ACTUATOR_JOURNAL_FLASH_SIZE + VG_ACTUATOR_JOURNAL_FLASH_CONFIG_SIZE)

_Static_assert(VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE == 3u * 4096u,
               "journal bank must occupy three 4 KiB sectors");
_Static_assert(VG_ACTUATOR_JOURNAL_FLASH_SIZE == 6u * 4096u,
               "journal must occupy six 4 KiB sectors");
_Static_assert(VG_ACTUATOR_JOURNAL_FLASH_PROTECTED_TAIL_SIZE == 7u * 4096u,
               "protected tail must include the final configuration sector");

typedef enum {
    VG_ACTUATOR_JOURNAL_FLASH_REGION_OK = 0,
    VG_ACTUATOR_JOURNAL_FLASH_REGION_INVALID_ARGUMENT,
    VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE,
} vg_actuator_journal_flash_region_result_t;

// Resolves a bounded byte range within one logical journal bank. The result is
// a physical flash offset, never an XIP address. Zero-length ranges are
// rejected so callers cannot accidentally treat an endpoint as writable.
vg_actuator_journal_flash_region_result_t vg_actuator_journal_flash_region_offset(
    uint32_t flash_size_bytes,
    size_t bank,
    size_t bank_offset,
    size_t length,
    uint32_t *flash_offset_out
);

// Resolves exactly one storage-manager page or sector. These helpers preserve
// the logical bank/index boundary and cannot resolve the configuration sector.
vg_actuator_journal_flash_region_result_t vg_actuator_journal_flash_region_page_offset(
    uint32_t flash_size_bytes,
    size_t bank,
    size_t page,
    uint32_t *flash_offset_out
);

vg_actuator_journal_flash_region_result_t vg_actuator_journal_flash_region_sector_offset(
    uint32_t flash_size_bytes,
    size_t bank,
    size_t sector,
    uint32_t *flash_offset_out
);
