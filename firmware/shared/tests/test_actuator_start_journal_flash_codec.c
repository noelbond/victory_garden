#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "actuator_start_journal_flash_codec.h"

#define PROTECTED_BYTES 248u
#define CRC_OFFSET 248u
#define CRC_INVERSE_OFFSET 252u

#define RECORD_LAYOUT_VERSION_OFFSET 4u
#define RECORD_LOGICAL_VERSION_OFFSET 5u
#define RECORD_TYPE_OFFSET 6u
#define RECORD_LINE_OFFSET 7u
#define RECORD_SEQUENCE_OFFSET 8u
#define RECORD_ISSUED_AT_OFFSET 16u
#define RECORD_KEY_LENGTH_OFFSET 24u
#define RECORD_ZONE_LENGTH_OFFSET 25u
#define RECORD_NODE_LENGTH_OFFSET 26u
#define RECORD_KEY_OFFSET 32u
#define RECORD_ZONE_OFFSET 127u
#define RECORD_NODE_OFFSET 158u
#define RECORD_RESERVED_OFFSET 189u

#define HEADER_LAYOUT_VERSION_OFFSET 4u
#define HEADER_GENERATION_OFFSET 8u
#define HEADER_SEQUENCE_HIGH_WATER_OFFSET 16u
#define HEADER_PAGE_SIZE_OFFSET 24u
#define HEADER_CAPACITY_OFFSET 26u
#define HEADER_RESERVED_OFFSET 28u

static void write_u32_le(uint8_t *bytes, uint32_t value) {
    for (size_t i = 0; i < 4u; ++i) {
        bytes[i] = (uint8_t)(value >> (i * 8u));
    }
}

static void refresh_integrity(uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    const uint32_t crc = vg_actuator_start_journal_flash_crc32(page, PROTECTED_BYTES);
    write_u32_le(page + CRC_OFFSET, crc);
    write_u32_le(page + CRC_INVERSE_OFFSET, ~crc);
}

static vg_actuator_start_journal_flash_accepted_record_t valid_record(void) {
    vg_actuator_start_journal_flash_accepted_record_t value;
    memset(&value, 0, sizeof(value));
    value.sequence = UINT64_C(0x0123456789ABCDEF);
    value.accepted_record.accepted = true;
    value.accepted_record.version = VG_ACTUATOR_START_JOURNAL_RECORD_VERSION;
    value.accepted_record.irrigation_line = 4u;
    value.accepted_record.issued_at_epoch_seconds = INT64_C(-62135596800);
    memcpy(value.accepted_record.idempotency_key, "key-1", sizeof("key-1"));
    memcpy(value.accepted_record.zone_id, "zone1", sizeof("zone1"));
    memcpy(value.accepted_record.node_id, "node1", sizeof("node1"));
    return value;
}

static vg_actuator_start_journal_flash_bank_header_t valid_header(void) {
    return (vg_actuator_start_journal_flash_bank_header_t){
        .generation = UINT64_C(0xFEDCBA9876543210),
        .sequence_high_water_mark = UINT64_C(0x0123456789ABCDEF),
        .record_page_size = VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE,
        .logical_capacity = VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY,
    };
}

static void assert_record_equal(const vg_actuator_start_journal_flash_accepted_record_t *actual,
                                const vg_actuator_start_journal_flash_accepted_record_t *expected) {
    assert(actual->sequence == expected->sequence);
    assert(actual->accepted_record.accepted == expected->accepted_record.accepted);
    assert(actual->accepted_record.version == expected->accepted_record.version);
    assert(actual->accepted_record.irrigation_line == expected->accepted_record.irrigation_line);
    assert(actual->accepted_record.issued_at_epoch_seconds == expected->accepted_record.issued_at_epoch_seconds);
    assert(strcmp(actual->accepted_record.idempotency_key, expected->accepted_record.idempotency_key) == 0);
    assert(strcmp(actual->accepted_record.zone_id, expected->accepted_record.zone_id) == 0);
    assert(strcmp(actual->accepted_record.node_id, expected->accepted_record.node_id) == 0);
}

static void assert_non_erased_invalid_record(const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    vg_actuator_start_journal_flash_accepted_record_t decoded;
    assert(!vg_actuator_start_journal_flash_page_is_erased(page));
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID);
}

static void assert_non_erased_invalid_header(const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    vg_actuator_start_journal_flash_bank_header_t decoded;
    assert(!vg_actuator_start_journal_flash_page_is_erased(page));
    assert(vg_actuator_start_journal_flash_decode_bank_header(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID);
}

static void test_crc32_reference_vector(void) {
    static const uint8_t bytes[] = "123456789";
    assert(vg_actuator_start_journal_flash_crc32(bytes, sizeof(bytes) - 1u) == UINT32_C(0xCBF43926));
}

static void test_record_round_trip_and_determinism(void) {
    const vg_actuator_start_journal_flash_accepted_record_t source = valid_record();
    vg_actuator_start_journal_flash_accepted_record_t decoded;
    uint8_t first[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    uint8_t second[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, first));
    assert(sizeof(first) == VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE);
    assert(vg_actuator_start_journal_flash_decode_accepted_record(first, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID);
    assert_record_equal(&decoded, &source);
    assert(vg_actuator_start_journal_flash_encode_accepted_record(&decoded, second));
    assert(memcmp(first, second, sizeof(first)) == 0);
}

static void test_record_signed_timestamp_line_and_sequence_round_trip(void) {
    vg_actuator_start_journal_flash_accepted_record_t source = valid_record();
    vg_actuator_start_journal_flash_accepted_record_t decoded;
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    source.sequence = UINT64_MAX;
    source.accepted_record.issued_at_epoch_seconds = INT64_MIN;
    source.accepted_record.irrigation_line = UINT8_MAX;
    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID);
    assert_record_equal(&decoded, &source);

    source.accepted_record.issued_at_epoch_seconds = INT64_MAX;
    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID);
    assert(decoded.accepted_record.issued_at_epoch_seconds == INT64_MAX);
}

static void fill_max_string(char *destination, size_t destination_size, char value) {
    assert(destination_size > 1u);
    memset(destination, value, destination_size - 1u);
    destination[destination_size - 1u] = '\0';
}

static void test_record_maximum_string_lengths_round_trip(void) {
    vg_actuator_start_journal_flash_accepted_record_t source = valid_record();
    vg_actuator_start_journal_flash_accepted_record_t decoded;
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    fill_max_string(source.accepted_record.idempotency_key,
                    sizeof(source.accepted_record.idempotency_key), 'k');
    fill_max_string(source.accepted_record.zone_id, sizeof(source.accepted_record.zone_id), 'z');
    fill_max_string(source.accepted_record.node_id, sizeof(source.accepted_record.node_id), 'n');
    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID);
    assert_record_equal(&decoded, &source);
}

static void test_record_empty_required_identifier_is_rejected(void) {
    vg_actuator_start_journal_flash_accepted_record_t source = valid_record();
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    source.accepted_record.idempotency_key[0] = '\0';
    assert(!vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    source = valid_record();
    source.accepted_record.zone_id[0] = '\0';
    assert(!vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    source = valid_record();
    source.accepted_record.node_id[0] = '\0';
    assert(!vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
}

static void test_record_important_corruption_is_invalid(void) {
    static const size_t offsets[] = {
        0u,
        RECORD_LAYOUT_VERSION_OFFSET,
        RECORD_LOGICAL_VERSION_OFFSET,
        RECORD_TYPE_OFFSET,
        RECORD_LINE_OFFSET,
        RECORD_SEQUENCE_OFFSET,
        RECORD_ISSUED_AT_OFFSET,
        RECORD_KEY_LENGTH_OFFSET,
        RECORD_KEY_OFFSET,
        CRC_OFFSET,
        CRC_INVERSE_OFFSET,
        RECORD_RESERVED_OFFSET,
    };
    const vg_actuator_start_journal_flash_accepted_record_t source = valid_record();
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    for (size_t i = 0; i < sizeof(offsets) / sizeof(offsets[0]); ++i) {
        assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
        page[offsets[i]] ^= 0x01u;
        assert_non_erased_invalid_record(page);
    }
}

static void test_record_canonical_string_rules_are_strict(void) {
    const vg_actuator_start_journal_flash_accepted_record_t source = valid_record();
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_KEY_LENGTH_OFFSET] = 0u;
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_KEY_LENGTH_OFFSET] = VG_ACTUATOR_START_JOURNAL_MAX_IDEMPOTENCY_KEY_LEN;
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_ZONE_LENGTH_OFFSET] = 0u;
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_NODE_LENGTH_OFFSET] = VG_ACTUATOR_START_JOURNAL_MAX_NODE_ID_LEN;
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_KEY_OFFSET + 1u] = '\0';
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_KEY_OFFSET + sizeof("key-1") - 1u] = 'x';
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_ZONE_OFFSET] = '\0';
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_NODE_OFFSET + sizeof("node1") - 1u] = 'x';
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_RESERVED_OFFSET] = 1u;
    refresh_integrity(page);
    assert_non_erased_invalid_record(page);
}

static void test_record_torn_writes_are_invalid(void) {
    static const size_t cuts[] = {1u, 18u, 40u, 100u, 247u, 250u, 255u};
    const vg_actuator_start_journal_flash_accepted_record_t source = valid_record();
    uint8_t valid[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    uint8_t torn[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, valid));
    for (size_t i = 0; i < sizeof(cuts) / sizeof(cuts[0]); ++i) {
        memset(torn, 0xFF, sizeof(torn));
        memcpy(torn, valid, cuts[i]);
        assert_non_erased_invalid_record(torn);
    }
}

static void test_record_erased_and_version_results(void) {
    const vg_actuator_start_journal_flash_accepted_record_t source = valid_record();
    vg_actuator_start_journal_flash_accepted_record_t decoded;
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    memset(page, 0xFF, sizeof(page));
    assert(vg_actuator_start_journal_flash_page_is_erased(page));
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_ERASED);
    page[255] = 0xFEu;
    assert_non_erased_invalid_record(page);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_LAYOUT_VERSION_OFFSET] = 0u;
    refresh_integrity(page);
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_LAYOUT_VERSION_OFFSET] = 2u;
    refresh_integrity(page);
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_LOGICAL_VERSION_OFFSET] = 1u;
    refresh_integrity(page);
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED);

    assert(vg_actuator_start_journal_flash_encode_accepted_record(&source, page));
    page[RECORD_TYPE_OFFSET] = 2u;
    refresh_integrity(page);
    assert(vg_actuator_start_journal_flash_decode_accepted_record(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED);
}

static void test_header_round_trip_and_determinism(void) {
    const vg_actuator_start_journal_flash_bank_header_t source = valid_header();
    vg_actuator_start_journal_flash_bank_header_t decoded;
    uint8_t first[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    uint8_t second[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    assert(vg_actuator_start_journal_flash_encode_bank_header(&source, first));
    assert(vg_actuator_start_journal_flash_decode_bank_header(first, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID);
    assert(decoded.generation == source.generation);
    assert(decoded.sequence_high_water_mark == source.sequence_high_water_mark);
    assert(decoded.record_page_size == source.record_page_size);
    assert(decoded.logical_capacity == source.logical_capacity);
    assert(vg_actuator_start_journal_flash_encode_bank_header(&decoded, second));
    assert(memcmp(first, second, sizeof(first)) == 0);
}

static void test_initial_and_maximum_header_high_water_round_trip(void) {
    vg_actuator_start_journal_flash_bank_header_t header = valid_header();
    vg_actuator_start_journal_flash_bank_header_t decoded;
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    header.generation = 1u;
    header.sequence_high_water_mark = 0u;
    assert(vg_actuator_start_journal_flash_encode_bank_header(&header, page));
    assert(vg_actuator_start_journal_flash_decode_bank_header(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID);
    assert(decoded.generation == 1u);
    assert(decoded.sequence_high_water_mark == 0u);

    header.sequence_high_water_mark = UINT64_MAX;
    assert(vg_actuator_start_journal_flash_encode_bank_header(&header, page));
    assert(vg_actuator_start_journal_flash_decode_bank_header(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID);
    assert(decoded.sequence_high_water_mark == UINT64_MAX);
}

static void test_header_invalid_encode_inputs_are_rejected(void) {
    vg_actuator_start_journal_flash_bank_header_t header = valid_header();
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    header.record_page_size = 255u;
    assert(!vg_actuator_start_journal_flash_encode_bank_header(&header, page));
    header = valid_header();
    header.logical_capacity = 31u;
    assert(!vg_actuator_start_journal_flash_encode_bank_header(&header, page));
}

static void test_header_corruption_and_torn_writes_are_invalid(void) {
    static const size_t offsets[] = {
        0u,
        HEADER_GENERATION_OFFSET,
        HEADER_SEQUENCE_HIGH_WATER_OFFSET,
        HEADER_PAGE_SIZE_OFFSET,
        HEADER_CAPACITY_OFFSET,
        CRC_OFFSET,
        CRC_INVERSE_OFFSET,
    };
    static const size_t cuts[] = {1u, 12u, 20u, 100u, 247u, 250u, 255u};
    const vg_actuator_start_journal_flash_bank_header_t source = valid_header();
    uint8_t valid[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    assert(vg_actuator_start_journal_flash_encode_bank_header(&source, valid));
    for (size_t i = 0; i < sizeof(offsets) / sizeof(offsets[0]); ++i) {
        memcpy(page, valid, sizeof(page));
        page[offsets[i]] ^= 0x01u;
        assert_non_erased_invalid_header(page);
    }

    memcpy(page, valid, sizeof(page));
    page[HEADER_RESERVED_OFFSET] = 1u;
    refresh_integrity(page);
    assert_non_erased_invalid_header(page);

    for (size_t i = 0; i < sizeof(cuts) / sizeof(cuts[0]); ++i) {
        memset(page, 0xFF, sizeof(page));
        memcpy(page, valid, cuts[i]);
        assert_non_erased_invalid_header(page);
    }
}

static void test_header_erased_and_unsupported_results(void) {
    const vg_actuator_start_journal_flash_bank_header_t source = valid_header();
    vg_actuator_start_journal_flash_bank_header_t decoded;
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE];

    memset(page, 0xFF, sizeof(page));
    assert(vg_actuator_start_journal_flash_decode_bank_header(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_ERASED);

    assert(vg_actuator_start_journal_flash_encode_bank_header(&source, page));
    page[HEADER_LAYOUT_VERSION_OFFSET] = 1u;
    refresh_integrity(page);
    assert(vg_actuator_start_journal_flash_decode_bank_header(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED);

    assert(vg_actuator_start_journal_flash_encode_bank_header(&source, page));
    page[HEADER_LAYOUT_VERSION_OFFSET] = 3u;
    refresh_integrity(page);
    assert(vg_actuator_start_journal_flash_decode_bank_header(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED);

    assert(vg_actuator_start_journal_flash_encode_bank_header(&source, page));
    page[HEADER_PAGE_SIZE_OFFSET + 1u] = 0u;
    refresh_integrity(page);
    assert(vg_actuator_start_journal_flash_decode_bank_header(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED);

    assert(vg_actuator_start_journal_flash_encode_bank_header(&source, page));
    page[HEADER_CAPACITY_OFFSET] = 0u;
    refresh_integrity(page);
    assert(vg_actuator_start_journal_flash_decode_bank_header(page, &decoded) ==
           VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED);
}

int main(void) {
    test_crc32_reference_vector();
    test_record_round_trip_and_determinism();
    test_record_signed_timestamp_line_and_sequence_round_trip();
    test_record_maximum_string_lengths_round_trip();
    test_record_empty_required_identifier_is_rejected();
    test_record_important_corruption_is_invalid();
    test_record_canonical_string_rules_are_strict();
    test_record_torn_writes_are_invalid();
    test_record_erased_and_version_results();
    test_header_round_trip_and_determinism();
    test_initial_and_maximum_header_high_water_round_trip();
    test_header_invalid_encode_inputs_are_rejected();
    test_header_corruption_and_torn_writes_are_invalid();
    test_header_erased_and_unsupported_results();
    puts("actuator_start_journal_flash_codec_tests: passed");
    return 0;
}
