#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "actuator_start_journal.h"

// This module defines only the immutable 256-byte on-flash representation.
// It deliberately has no physical-flash, Pico SDK, or bank-selection knowledge.
#define VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE 256u
#define VG_ACTUATOR_START_JOURNAL_FLASH_RECORD_LAYOUT_VERSION 1u
#define VG_ACTUATOR_START_JOURNAL_FLASH_BANK_HEADER_LAYOUT_VERSION 2u
#define VG_ACTUATOR_START_JOURNAL_FLASH_ACCEPTED_RECORD_TYPE 1u
#define VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY 32u

typedef enum {
    // Every byte is 0xFF and the page is available for a future program.
    VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_ERASED = 0,
    // The page is authentic, supported, canonical, and safe to load.
    VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID,
    // A non-erased page is malformed, torn, noncanonical, or corrupt.
    VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID,
    // Integrity is sound, but its format, logical version, or type is unknown.
    VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED,
} vg_actuator_start_journal_flash_page_result_t;

typedef struct {
    uint64_t sequence;
    vg_actuator_start_journal_record_t accepted_record;
} vg_actuator_start_journal_flash_accepted_record_t;

typedef struct {
    uint64_t generation;
    // Immutable baseline for this bank. Future bank scanning computes the
    // current high-water as max(this value, every valid record sequence).
    uint64_t sequence_high_water_mark;
    uint16_t record_page_size;
    uint16_t logical_capacity;
} vg_actuator_start_journal_flash_bank_header_t;

// Computes the standard reflected CRC-32/ISO-HDLC value used by both page
// formats. The encoder and decoder protect bytes [0, 247] inclusive.
uint32_t vg_actuator_start_journal_flash_crc32(const uint8_t *bytes, size_t length);

// Returns true only when every byte in the exactly-sized page is 0xFF.
bool vg_actuator_start_journal_flash_page_is_erased(
    const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
);

// Encodes one immutable accepted START page. The destination is always fully
// initialized to the canonical current-layout form on success.
bool vg_actuator_start_journal_flash_encode_accepted_record(
    const vg_actuator_start_journal_flash_accepted_record_t *record,
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
);

// Decodes an accepted START page. record_out is changed only for VALID pages.
vg_actuator_start_journal_flash_page_result_t
vg_actuator_start_journal_flash_decode_accepted_record(
    const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE],
    vg_actuator_start_journal_flash_accepted_record_t *record_out
);

// Encodes an immutable bank header. A valid header becomes authoritative only
// when the future dual-bank algorithm chooses it; this codec makes no choice.
bool vg_actuator_start_journal_flash_encode_bank_header(
    const vg_actuator_start_journal_flash_bank_header_t *header,
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
);

// Decodes a bank header. header_out is changed only for VALID pages.
vg_actuator_start_journal_flash_page_result_t
vg_actuator_start_journal_flash_decode_bank_header(
    const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE],
    vg_actuator_start_journal_flash_bank_header_t *header_out
);
