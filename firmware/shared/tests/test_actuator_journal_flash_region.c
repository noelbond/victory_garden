#include <assert.h>
#include <stdint.h>

#include "actuator_journal_flash_region.h"

#define PICO_W_FLASH_SIZE (2u * 1024u * 1024u)
#define PICO_2_W_FLASH_SIZE (4u * 1024u * 1024u)

static void assert_page_offset(uint32_t flash_size, size_t bank, size_t page, uint32_t expected) {
    uint32_t actual = 0u;
    assert(vg_actuator_journal_flash_region_page_offset(flash_size, bank, page, &actual) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_OK);
    assert(actual == expected);
}

static void assert_sector_offset(uint32_t flash_size, size_t bank, size_t sector, uint32_t expected) {
    uint32_t actual = 0u;
    assert(vg_actuator_journal_flash_region_sector_offset(flash_size, bank, sector, &actual) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_OK);
    assert(actual == expected);
}

static void test_pico_w_offsets(void) {
    assert_page_offset(PICO_W_FLASH_SIZE, 0u, 0u, 0x1F9000u);
    assert_page_offset(PICO_W_FLASH_SIZE, 0u, 47u, 0x1FBF00u);
    assert_page_offset(PICO_W_FLASH_SIZE, 1u, 0u, 0x1FC000u);
    assert_page_offset(PICO_W_FLASH_SIZE, 1u, 47u, 0x1FEF00u);
    assert_sector_offset(PICO_W_FLASH_SIZE, 0u, 0u, 0x1F9000u);
    assert_sector_offset(PICO_W_FLASH_SIZE, 1u, 2u, 0x1FE000u);
}

static void test_pico_2_w_offsets(void) {
    assert_page_offset(PICO_2_W_FLASH_SIZE, 0u, 0u, 0x3F9000u);
    assert_page_offset(PICO_2_W_FLASH_SIZE, 0u, 47u, 0x3FBF00u);
    assert_page_offset(PICO_2_W_FLASH_SIZE, 1u, 0u, 0x3FC000u);
    assert_page_offset(PICO_2_W_FLASH_SIZE, 1u, 47u, 0x3FEF00u);
}

static void test_rejections(void) {
    uint32_t output = 0u;
    assert(vg_actuator_journal_flash_region_page_offset(PICO_W_FLASH_SIZE, 2u, 0u, &output) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE);
    assert(vg_actuator_journal_flash_region_page_offset(PICO_W_FLASH_SIZE, 0u, 48u, &output) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE);
    assert(vg_actuator_journal_flash_region_sector_offset(PICO_W_FLASH_SIZE, 0u, 3u, &output) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE);
    assert(vg_actuator_journal_flash_region_offset(PICO_W_FLASH_SIZE, 1u,
                                                    VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE - 128u,
                                                    256u, &output) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE);
    // This is the first byte of the final configuration sector. It is not a
    // valid journal-bank endpoint and therefore cannot be resolved here.
    assert(vg_actuator_journal_flash_region_offset(PICO_W_FLASH_SIZE, 1u,
                                                    VG_ACTUATOR_JOURNAL_FLASH_BANK_SIZE,
                                                    1u, &output) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE);
    assert(vg_actuator_journal_flash_region_offset(PICO_W_FLASH_SIZE, 0u, 0u, 0u, &output) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_INVALID_ARGUMENT);
    assert(vg_actuator_journal_flash_region_offset(PICO_W_FLASH_SIZE, 0u, 0u, 256u, NULL) ==
           VG_ACTUATOR_JOURNAL_FLASH_REGION_INVALID_ARGUMENT);
    assert(vg_actuator_journal_flash_region_offset(
               VG_ACTUATOR_JOURNAL_FLASH_PROTECTED_TAIL_SIZE - 1u, 0u, 0u, 256u, &output
           ) == VG_ACTUATOR_JOURNAL_FLASH_REGION_OUT_OF_RANGE);
}

int main(void) {
    test_pico_w_offsets();
    test_pico_2_w_offsets();
    test_rejections();
    return 0;
}
