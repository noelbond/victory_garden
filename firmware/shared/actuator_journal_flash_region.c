#include "actuator_journal_flash_region.h"

static bool flash_has_protected_tail(uint32_t flash_size_bytes) {
    return flash_size_bytes >= VG_ACTUATOR_JOURNAL_FLASH_PROTECTED_TAIL_SIZE;
}

vg_actuator_journal_flash_region_result_t vg_actuator_journal_flash_region_offset(
    uint32_t flash_size_bytes,
    size_t bank,
    size_t bank_offset,
    size_t length,
    uint32_t *flash_offset_out
) {
    if (!flash_offset_out || length == 0u) {
        return VG_ACTUATOR_JOURNAL_FLASH_REGION_INVALID_ARGUMENT;
    }
    if (!flash_has_protected_tail(flash_size_bytes) ||
        bank >= VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT ||
        bank_offset >= VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE ||
        length > VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE - bank_offset) {
        return VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE;
    }

    const uint32_t journal_base =
        flash_size_bytes - VG_ACTUATOR_JOURNAL_FLASH_PROTECTED_TAIL_SIZE;
    const size_t resolved_offset = (size_t)journal_base +
                                   bank * VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE + bank_offset;
    if (resolved_offset > UINT32_MAX) {
        return VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE;
    }
    *flash_offset_out = (uint32_t)resolved_offset;
    return VG_ACTUATOR_JOURNAL_FLASH_REGION_OK;
}

vg_actuator_journal_flash_region_result_t vg_actuator_journal_flash_region_page_offset(
    uint32_t flash_size_bytes,
    size_t bank,
    size_t page,
    uint32_t *flash_offset_out
) {
    if (page >= VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK) {
        return VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE;
    }
    return vg_actuator_journal_flash_region_offset(
        flash_size_bytes,
        bank,
        page * VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
        VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
        flash_offset_out
    );
}

vg_actuator_journal_flash_region_result_t vg_actuator_journal_flash_region_sector_offset(
    uint32_t flash_size_bytes,
    size_t bank,
    size_t sector,
    uint32_t *flash_offset_out
) {
    if (sector >= VG_ACTUATOR_START_JOURNAL_STORAGE_SECTORS_PER_BANK) {
        return VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE;
    }
    return vg_actuator_journal_flash_region_offset(
        flash_size_bytes,
        bank,
        sector * VG_ACTUATOR_START_JOURNAL_STORAGE_SECTOR_SIZE,
        VG_ACTUATOR_START_JOURNAL_STORAGE_SECTOR_SIZE,
        flash_offset_out
    );
}
