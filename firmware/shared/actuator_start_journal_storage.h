#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "actuator_start_journal.h"
#include "actuator_start_journal_flash_codec.h"

// Logical-only geometry. This module deliberately knows no physical address.
#define VG_ACTUATOR_START_JOURNAL_STORAGE_BANK_COUNT 2u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_SECTORS_PER_BANK 3u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_SECTOR_SIZE 4096u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_SECTOR 16u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK 48u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_HEADER_PAGE 0u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RECORD_PAGE 1u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT 32u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_FIRST_RESERVED_PAGE 33u
#define VG_ACTUATOR_START_JOURNAL_STORAGE_RESERVED_PAGE_COUNT 15u

_Static_assert(VG_ACTUATOR_START_JOURNAL_STORAGE_SECTORS_PER_BANK *
                   VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_SECTOR ==
                   VG_ACTUATOR_START_JOURNAL_STORAGE_PAGES_PER_BANK,
               "bank geometry must be exact");
_Static_assert(VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT ==
                   VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY,
               "record area must match the logical journal capacity");

typedef struct {
    void *context;
    bool (*read_page)(void *context, size_t bank, size_t page,
                      uint8_t out[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]);
    bool (*program_page)(void *context, size_t bank, size_t page,
                         const uint8_t bytes[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]);
    bool (*erase_sector)(void *context, size_t bank, size_t sector);
} vg_actuator_start_journal_storage_backend_t;

typedef enum {
    VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK = 0,
    VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_EMPTY,
    VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS,
    // A supported authoritative bank exists, but the other bank is dirty and
    // must be cleaned before it can participate in another rollover.
    VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_REQUIRED,
    VG_ACTUATOR_START_JOURNAL_STORAGE_CORRUPT,
    VG_ACTUATOR_START_JOURNAL_STORAGE_UNSUPPORTED,
} vg_actuator_start_journal_storage_state_t;

typedef enum {
    VG_ACTUATOR_START_JOURNAL_STORAGE_OK = 0,
    VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_BLANK,
    VG_ACTUATOR_START_JOURNAL_STORAGE_NOT_READY,
    VG_ACTUATOR_START_JOURNAL_STORAGE_FULL,
    VG_ACTUATOR_START_JOURNAL_STORAGE_SEQUENCE_EXHAUSTED,
    VG_ACTUATOR_START_JOURNAL_STORAGE_GENERATION_EXHAUSTED,
    VG_ACTUATOR_START_JOURNAL_STORAGE_CLEANUP_NEEDED,
    VG_ACTUATOR_START_JOURNAL_STORAGE_BACKEND_FAILURE,
    VG_ACTUATOR_START_JOURNAL_STORAGE_VERIFY_FAILURE,
    VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_ARGUMENT,
    VG_ACTUATOR_START_JOURNAL_STORAGE_INVALID_RETAINED_SNAPSHOT,
} vg_actuator_start_journal_storage_result_t;

typedef struct {
    vg_actuator_start_journal_storage_backend_t backend;
    vg_actuator_start_journal_storage_state_t state;
    size_t authoritative_bank;
    vg_actuator_start_journal_flash_bank_header_t header;
    uint64_t current_high_water;
    size_t record_count;
    vg_actuator_start_journal_flash_accepted_record_t records[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    // The reconstructed logical view has the same immutable accepted history.
    vg_actuator_start_journal_record_t logical_records[
        VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    vg_actuator_start_journal_t logical_journal;
} vg_actuator_start_journal_storage_t;

// Reconstructs state from durable pages as a reboot would. It performs no
// mutation. Only BLANK, HEALTHY_*, and CLEANUP_REQUIRED permit known history.
vg_actuator_start_journal_storage_state_t vg_actuator_start_journal_storage_open(
    vg_actuator_start_journal_storage_t *storage,
    const vg_actuator_start_journal_storage_backend_t *backend
);

// Initializes only fully erased dual-bank storage. It writes and verifies the
// generation-1, high-water-0 header in bank zero.
vg_actuator_start_journal_storage_result_t vg_actuator_start_journal_storage_initialize(
    vg_actuator_start_journal_storage_t *storage
);

// Durably appends and verifies an immutable accepted START record. The caller
// invokes logical commit_verified only after this returns OK.
vg_actuator_start_journal_storage_result_t vg_actuator_start_journal_storage_append_verified(
    vg_actuator_start_journal_storage_t *storage,
    const vg_actuator_start_journal_record_t *record,
    uint64_t *sequence_out
);

// Compacts an explicit caller-selected subset of the current durable history.
// It makes no freshness decision. retained records must be exact members in
// ascending sequence order. Header-last activation preserves high-water even
// when the subset is empty.
vg_actuator_start_journal_storage_result_t vg_actuator_start_journal_storage_compact(
    vg_actuator_start_journal_storage_t *storage,
    const vg_actuator_start_journal_flash_accepted_record_t *retained,
    size_t retained_count
);

// Erases the non-authoritative bank only when a valid authority exists. This
// is a separate maintenance operation so runtime policy can gate erase later.
vg_actuator_start_journal_storage_result_t vg_actuator_start_journal_storage_cleanup_inactive(
    vg_actuator_start_journal_storage_t *storage
);

bool vg_actuator_start_journal_storage_is_start_enabled(
    const vg_actuator_start_journal_storage_t *storage
);

