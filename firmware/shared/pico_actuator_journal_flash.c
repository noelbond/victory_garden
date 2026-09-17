#include "pico_actuator_journal_flash.h"

#include <limits.h>
#include <stdbool.h>
#include <string.h>

#include "hardware/flash.h"
#include "hardware/regs/addressmap.h"
#include "pico/flash.h"
#include "pico/error.h"
#include "pico/platform.h"

#include "actuator_journal_flash_region.h"
#include "actuator_persistent_flash_layout.h"

_Static_assert(FLASH_PAGE_SIZE == VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
               "Pico page program size must match journal page size");
_Static_assert(FLASH_SECTOR_SIZE == VG_ACTUATOR_START_JOURNAL_STORAGE_SECTOR_SIZE,
               "Pico sector erase size must match journal sector size");
_Static_assert(VG_ACTUATOR_PERSISTENT_BANK_SIZE == VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE,
               "Pico persistent layout and journal bank geometry must agree");
_Static_assert(VG_ACTUATOR_PERSISTENT_JOURNAL_SIZE == VG_ACTUATOR_JOURNAL_FLASH_SIZE,
               "Pico persistent layout and journal size must agree");
_Static_assert(VG_ACTUATOR_PERSISTENT_CONFIG_OFFSET ==
                   VG_ACTUATOR_PERSISTENT_BANK_B_OFFSET + VG_ACTUATOR_PERSISTENT_BANK_SIZE,
               "configuration sector must begin immediately after bank B");

typedef enum {
    VG_PICO_ACTUATOR_JOURNAL_MUTATION_PROGRAM_PAGE = 0,
    VG_PICO_ACTUATOR_JOURNAL_MUTATION_ERASE_SECTOR,
} vg_pico_actuator_journal_mutation_kind_t;

typedef struct {
    vg_pico_actuator_journal_mutation_kind_t kind;
    uint32_t flash_offset;
    // This structure is caller-stack storage and therefore SRAM-resident. The
    // page copy ensures the callback never reads a source pointer from XIP.
    uint8_t page_bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
} vg_pico_actuator_journal_mutation_t;

static vg_pico_actuator_journal_flash_result_t remember_result(
    vg_pico_actuator_journal_flash_t *journal_flash,
    vg_pico_actuator_journal_flash_result_t result
) {
    if (journal_flash) {
        journal_flash->last_result = result;
    }
    return result;
}

static vg_pico_actuator_journal_flash_result_t region_result(
    vg_actuator_journal_flash_region_result_t result
) {
    switch (result) {
        case VG_ACTUATOR_JOURNAL_FLASH_REGION_OK:
            return VG_PICO_ACTUATOR_JOURNAL_FLASH_OK;
        case VG_ACTUATOR_JOURNAL_FLASH_REGION_INVALID_ARGUMENT:
            return VG_PICO_ACTUATOR_JOURNAL_FLASH_INVALID_ARGUMENT;
        case VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE:
        default:
            return VG_PICO_ACTUATOR_JOURNAL_FLASH_OUT_OF_RANGE;
    }
}

static bool page_is_erased(uint32_t flash_offset) {
    const uint8_t *page = (const uint8_t *)(uintptr_t)(XIP_BASE + flash_offset);
    for (size_t index = 0u; index < FLASH_PAGE_SIZE; ++index) {
        if (page[index] != 0xFFu) {
            return false;
        }
    }
    return true;
}

// No logging, allocation, application callbacks, or flash-resident source
// data are used after flash_safe_execute disables XIP/interrupt activity.
static void __not_in_flash_func(perform_journal_mutation)(void *parameter) {
    const vg_pico_actuator_journal_mutation_t *mutation = parameter;
    if (mutation->kind == VG_PICO_ACTUATOR_JOURNAL_MUTATION_PROGRAM_PAGE) {
        flash_range_program(mutation->flash_offset, mutation->page_bytes, FLASH_PAGE_SIZE);
    } else {
        flash_range_erase(mutation->flash_offset, FLASH_SECTOR_SIZE);
    }
}

static vg_pico_actuator_journal_flash_result_t perform_mutation(
    vg_pico_actuator_journal_flash_t *journal_flash,
    vg_pico_actuator_journal_mutation_t *mutation
) {
    // This timeout is only the SDK's core-lockout enter/exit timeout. It is
    // deliberately not a guessed active-output flash-duration guard.
    const int safe_execute_result =
        flash_safe_execute(perform_journal_mutation, mutation, UINT32_MAX);
    return remember_result(journal_flash,
                           safe_execute_result == PICO_OK
                               ? VG_PICO_ACTUATOR_JOURNAL_FLASH_OK
                               : VG_PICO_ACTUATOR_JOURNAL_FLASH_SAFE_EXECUTE_FAILED);
}

void vg_pico_actuator_journal_flash_init(vg_pico_actuator_journal_flash_t *journal_flash) {
    if (journal_flash) {
        journal_flash->last_result = VG_PICO_ACTUATOR_JOURNAL_FLASH_OK;
    }
}

vg_pico_actuator_journal_flash_result_t vg_pico_actuator_journal_flash_read(
    vg_pico_actuator_journal_flash_t *journal_flash,
    size_t bank,
    size_t bank_offset,
    uint8_t *destination,
    size_t length
) {
    if (!journal_flash || !destination) {
        return remember_result(journal_flash, VG_PICO_ACTUATOR_JOURNAL_FLASH_INVALID_ARGUMENT);
    }
    uint32_t flash_offset = 0u;
    const vg_pico_actuator_journal_flash_result_t result = region_result(
        vg_actuator_journal_flash_region_offset(PICO_FLASH_SIZE_BYTES, bank, bank_offset,
                                                length, &flash_offset)
    );
    if (result != VG_PICO_ACTUATOR_JOURNAL_FLASH_OK) {
        return remember_result(journal_flash, result);
    }
    memcpy(destination, (const void *)(uintptr_t)(XIP_BASE + flash_offset), length);
    return remember_result(journal_flash, VG_PICO_ACTUATOR_JOURNAL_FLASH_OK);
}

vg_pico_actuator_journal_flash_result_t vg_pico_actuator_journal_flash_program_page(
    vg_pico_actuator_journal_flash_t *journal_flash,
    size_t bank,
    size_t page,
    const uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
) {
    if (!journal_flash || !bytes) {
        return remember_result(journal_flash, VG_PICO_ACTUATOR_JOURNAL_FLASH_INVALID_ARGUMENT);
    }
    uint32_t flash_offset = 0u;
    const vg_pico_actuator_journal_flash_result_t result = region_result(
        vg_actuator_journal_flash_region_page_offset(PICO_FLASH_SIZE_BYTES, bank, page,
                                                     &flash_offset)
    );
    if (result != VG_PICO_ACTUATOR_JOURNAL_FLASH_OK) {
        return remember_result(journal_flash, result);
    }
    if (!page_is_erased(flash_offset)) {
        return remember_result(journal_flash,
                               VG_PICO_ACTUATOR_JOURNAL_FLASH_DESTINATION_NOT_ERASED);
    }

    vg_pico_actuator_journal_mutation_t mutation = {
        .kind = VG_PICO_ACTUATOR_JOURNAL_MUTATION_PROGRAM_PAGE,
        .flash_offset = flash_offset,
    };
    memcpy(mutation.page_bytes, bytes, sizeof(mutation.page_bytes));
    return perform_mutation(journal_flash, &mutation);
}

vg_pico_actuator_journal_flash_result_t vg_pico_actuator_journal_flash_erase_sector(
    vg_pico_actuator_journal_flash_t *journal_flash,
    size_t bank,
    size_t sector
) {
    if (!journal_flash) {
        return VG_PICO_ACTUATOR_JOURNAL_FLASH_INVALID_ARGUMENT;
    }
    uint32_t flash_offset = 0u;
    const vg_pico_actuator_journal_flash_result_t result = region_result(
        vg_actuator_journal_flash_region_sector_offset(PICO_FLASH_SIZE_BYTES, bank, sector,
                                                       &flash_offset)
    );
    if (result != VG_PICO_ACTUATOR_JOURNAL_FLASH_OK) {
        return remember_result(journal_flash, result);
    }
    vg_pico_actuator_journal_mutation_t mutation = {
        .kind = VG_PICO_ACTUATOR_JOURNAL_MUTATION_ERASE_SECTOR,
        .flash_offset = flash_offset,
    };
    return perform_mutation(journal_flash, &mutation);
}

vg_pico_actuator_journal_flash_result_t vg_pico_actuator_journal_flash_last_result(
    const vg_pico_actuator_journal_flash_t *journal_flash
) {
    return journal_flash ? journal_flash->last_result
                         : VG_PICO_ACTUATOR_JOURNAL_FLASH_INVALID_ARGUMENT;
}

static bool backend_read_page(void *context, size_t bank, size_t page,
                              uint8_t output[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    return vg_pico_actuator_journal_flash_read(
               context,
               bank,
               page * VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
               output,
               VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE
           ) == VG_PICO_ACTUATOR_JOURNAL_FLASH_OK;
}

static bool backend_program_page(void *context, size_t bank, size_t page,
                                 const uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    return vg_pico_actuator_journal_flash_program_page(context, bank, page, bytes) ==
           VG_PICO_ACTUATOR_JOURNAL_FLASH_OK;
}

static bool backend_erase_sector(void *context, size_t bank, size_t sector) {
    return vg_pico_actuator_journal_flash_erase_sector(context, bank, sector) ==
           VG_PICO_ACTUATOR_JOURNAL_FLASH_OK;
}

vg_actuator_start_journal_storage_backend_t vg_pico_actuator_journal_flash_backend(
    vg_pico_actuator_journal_flash_t *journal_flash
) {
    return (vg_actuator_start_journal_storage_backend_t){
        .context = journal_flash,
        .read_page = backend_read_page,
        .program_page = backend_program_page,
        .erase_sector = backend_erase_sector,
    };
}
