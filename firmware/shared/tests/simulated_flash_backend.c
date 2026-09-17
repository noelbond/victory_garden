#include "simulated_flash_backend.h"

#include <string.h>

static void append_trace(vg_simulated_flash_backend_t *flash,
                         vg_simulated_flash_trace_operation_t operation,
                         size_t bank, size_t index) {
    if (flash->trace_count < VG_SIMULATED_FLASH_MAX_TRACE_ENTRIES) {
        flash->trace[flash->trace_count++] = (vg_simulated_flash_trace_entry_t){
            .operation = operation,
            .bank = bank,
            .index = index,
        };
    }
}

static bool fault_matches(vg_simulated_flash_backend_t *flash,
                          vg_simulated_flash_fault_t requested) {
    if (flash->fault != requested) {
        return false;
    }
    ++flash->matching_mutation_count;
    return flash->matching_mutation_count == flash->fault_occurrence;
}

void vg_simulated_flash_backend_init(vg_simulated_flash_backend_t *flash) {
    if (!flash) {
        return;
    }
    memset(flash, 0xFF, sizeof(flash->bytes));
    flash->trace_count = 0u;
    flash->fault = VG_SIMULATED_FLASH_FAULT_NONE;
    flash->fault_occurrence = 0u;
    flash->matching_mutation_count = 0u;
    flash->partial_bytes = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE / 2u;
}

void vg_simulated_flash_backend_set_fault(vg_simulated_flash_backend_t *flash,
                                          vg_simulated_flash_fault_t fault,
                                          size_t occurrence, size_t partial_bytes) {
    if (!flash) {
        return;
    }
    flash->fault = fault;
    flash->fault_occurrence = occurrence == 0u ? 1u : occurrence;
    flash->matching_mutation_count = 0u;
    flash->partial_bytes = partial_bytes == 0u ? 1u : partial_bytes;
}

void vg_simulated_flash_backend_clear_fault(vg_simulated_flash_backend_t *flash) {
    if (!flash) {
        return;
    }
    flash->fault = VG_SIMULATED_FLASH_FAULT_NONE;
    flash->fault_occurrence = 0u;
    flash->matching_mutation_count = 0u;
}

static bool simulated_read_page(void *context, size_t bank, size_t page,
                                uint8_t out[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    vg_simulated_flash_backend_t *flash = context;
    if (!flash || !out || bank >= VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT ||
        page >= VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK) {
        return false;
    }
    memcpy(out, flash->bytes[bank][page], VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE);
    return true;
}

static bool page_is_erased(const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    for (size_t index = 0; index < VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE; ++index) {
        if (page[index] != 0xFFu) {
            return false;
        }
    }
    return true;
}

static void program_bytes(uint8_t *destination, const uint8_t *source, size_t length) {
    for (size_t index = 0; index < length; ++index) {
        destination[index] &= source[index];
    }
}

static bool simulated_program_page(void *context, size_t bank, size_t page,
                                   const uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    vg_simulated_flash_backend_t *flash = context;
    if (!flash || !bytes || bank >= VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT ||
        page >= VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK ||
        !page_is_erased(flash->bytes[bank][page])) {
        return false;
    }
    append_trace(flash, VG_SIMULATED_FLASH_TRACE_PROGRAM, bank, page);
    if (fault_matches(flash, VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM)) {
        return false;
    }
    if (fault_matches(flash, VG_SIMULATED_FLASH_FAULT_DURING_PROGRAM)) {
        size_t count = flash->partial_bytes;
        if (count >= VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE) {
            count = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE - 1u;
        }
        program_bytes(flash->bytes[bank][page], bytes, count);
        return false;
    }
    program_bytes(flash->bytes[bank][page], bytes, VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE);
    return !fault_matches(flash, VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM);
}

static bool simulated_erase_sector(void *context, size_t bank, size_t sector) {
    vg_simulated_flash_backend_t *flash = context;
    if (!flash || bank >= VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT ||
        sector >= VG_ACTUATOR_START_JOURNAL_STORAGE_SECTORS_PER_BANK) {
        return false;
    }
    append_trace(flash, VG_SIMULATED_FLASH_TRACE_ERASE, bank, sector);
    if (fault_matches(flash, VG_SIMULATED_FLASH_FAULT_BEFORE_ERASE)) {
        return false;
    }
    uint8_t *sector_bytes = &flash->bytes[bank][sector * VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_SECTOR][0];
    const size_t sector_size = VG_ACTUATOR_START_JOURNAL_STORAGE_SECTOR_SIZE;
    if (fault_matches(flash, VG_SIMULATED_FLASH_FAULT_DURING_ERASE)) {
        size_t count = flash->partial_bytes;
        if (count >= sector_size) {
            count = sector_size - 1u;
        }
        memset(sector_bytes, 0xFF, count);
        return false;
    }
    memset(sector_bytes, 0xFF, sector_size);
    return !fault_matches(flash, VG_SIMULATED_FLASH_FAULT_AFTER_ERASE);
}

vg_actuator_start_journal_storage_backend_t vg_simulated_flash_backend_interface(
    vg_simulated_flash_backend_t *flash
) {
    return (vg_actuator_start_journal_storage_backend_t){
        .context = flash,
        .read_page = simulated_read_page,
        .program_page = simulated_program_page,
        .erase_sector = simulated_erase_sector,
    };
}
