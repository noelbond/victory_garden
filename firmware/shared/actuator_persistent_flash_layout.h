#pragma once

#include <stdint.h>

#include "hardware/flash.h"
#include "hardware/regs/addressmap.h"

#include "actuator_start_journal_storage.h"

// This is physical placement only. The durable journal manager remains pure
// and does not include this header or know any flash address.
#define VG_ACTUATOR_PERSISTENT_SECTOR_SIZE FLASH_SECTOR_SIZE
#define VG_ACTUATOR_PERSISTENT_PAGE_SIZE FLASH_PAGE_SIZE
#define VG_ACTUATOR_PERSISTENT_BANK_SECTOR_COUNT \
    VG_ACTUATOR_START_JOURNAL_STORAGE_SECTORS_PER_BANK
#define VG_ACTUATOR_PERSISTENT_BANK_SIZE \
    (VG_ACTUATOR_PERSISTENT_BANK_SECTOR_COUNT * VG_ACTUATOR_PERSISTENT_SECTOR_SIZE)
#define VG_ACTUATOR_PERSISTENT_JOURNAL_BANK_COUNT \
    VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT
#define VG_ACTUATOR_PERSISTENT_JOURNAL_SIZE \
    (VG_ACTUATOR_PERSISTENT_JOURNAL_BANK_COUNT * VG_ACTUATOR_PERSISTENT_BANK_SIZE)
#define VG_ACTUATOR_PERSISTENT_CONFIG_SIZE VG_ACTUATOR_PERSISTENT_SECTOR_SIZE
#define VG_ACTUATOR_PERSISTENT_PROTECTED_TAIL_SIZE \
    (VG_ACTUATOR_PERSISTENT_JOURNAL_SIZE + VG_ACTUATOR_PERSISTENT_CONFIG_SIZE)

#define VG_ACTUATOR_PERSISTENT_JOURNAL_BASE_OFFSET \
    (PICO_FLASH_SIZE_BYTES - VG_ACTUATOR_PERSISTENT_PROTECTED_TAIL_SIZE)
#define VG_ACTUATOR_PERSISTENT_BANK_A_OFFSET VG_ACTUATOR_PERSISTENT_JOURNAL_BASE_OFFSET
#define VG_ACTUATOR_PERSISTENT_BANK_B_OFFSET \
    (VG_ACTUATOR_PERSISTENT_BANK_A_OFFSET + VG_ACTUATOR_PERSISTENT_BANK_SIZE)
#define VG_ACTUATOR_PERSISTENT_CONFIG_OFFSET \
    (PICO_FLASH_SIZE_BYTES - VG_ACTUATOR_PERSISTENT_CONFIG_SIZE)
#define VG_ACTUATOR_PERSISTENT_JOURNAL_BASE_ADDRESS \
    (XIP_BASE + VG_ACTUATOR_PERSISTENT_JOURNAL_BASE_OFFSET)

_Static_assert(VG_ACTUATOR_PERSISTENT_SECTOR_SIZE == 4096u,
               "persistent tail requires 4 KiB flash sectors");
_Static_assert(VG_ACTUATOR_PERSISTENT_PAGE_SIZE == VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
               "persistent tail and journal codec must agree on page size");
_Static_assert(VG_ACTUATOR_PERSISTENT_BANK_SIZE ==
                   VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK *
                       VG_ACTUATOR_PERSISTENT_PAGE_SIZE,
               "bank byte and page geometry must agree");
_Static_assert(VG_ACTUATOR_PERSISTENT_JOURNAL_BASE_OFFSET %
                   VG_ACTUATOR_PERSISTENT_SECTOR_SIZE == 0u,
               "journal base must be sector aligned");
_Static_assert(VG_ACTUATOR_PERSISTENT_BANK_B_OFFSET %
                   VG_ACTUATOR_PERSISTENT_SECTOR_SIZE == 0u,
               "bank B must be sector aligned");
_Static_assert(VG_ACTUATOR_PERSISTENT_CONFIG_OFFSET %
                   VG_ACTUATOR_PERSISTENT_SECTOR_SIZE == 0u,
               "configuration sector must be sector aligned");
_Static_assert(VG_ACTUATOR_PERSISTENT_BANK_A_OFFSET + VG_ACTUATOR_PERSISTENT_BANK_SIZE ==
                   VG_ACTUATOR_PERSISTENT_BANK_B_OFFSET,
               "journal banks must be adjacent without overlap");
_Static_assert(VG_ACTUATOR_PERSISTENT_BANK_B_OFFSET + VG_ACTUATOR_PERSISTENT_BANK_SIZE ==
                   VG_ACTUATOR_PERSISTENT_CONFIG_OFFSET,
               "journal bank B must end at the configuration sector");
_Static_assert(VG_ACTUATOR_PERSISTENT_CONFIG_OFFSET + VG_ACTUATOR_PERSISTENT_CONFIG_SIZE ==
                   PICO_FLASH_SIZE_BYTES,
               "configuration sector must remain the final flash sector");
_Static_assert(PICO_FLASH_SIZE_BYTES >= VG_ACTUATOR_PERSISTENT_PROTECTED_TAIL_SIZE,
               "flash is too small for the protected actuator persistent tail");
