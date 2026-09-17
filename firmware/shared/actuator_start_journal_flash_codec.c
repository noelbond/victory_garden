#include "actuator_start_journal_flash_codec.h"

#include <string.h>

#define VG_FLASH_PAGE_PROTECTED_BYTES 248u
#define VG_FLASH_PAGE_CRC_OFFSET 248u
#define VG_FLASH_PAGE_CRC_INVERSE_OFFSET 252u

#define VG_FLASH_RECORD_MAGIC_OFFSET 0u
#define VG_FLASH_RECORD_LAYOUT_VERSION_OFFSET 4u
#define VG_FLASH_RECORD_LOGICAL_VERSION_OFFSET 5u
#define VG_FLASH_RECORD_TYPE_OFFSET 6u
#define VG_FLASH_RECORD_LINE_OFFSET 7u
#define VG_FLASH_RECORD_SEQUENCE_OFFSET 8u
#define VG_FLASH_RECORD_ISSUED_AT_OFFSET 16u
#define VG_FLASH_RECORD_KEY_LENGTH_OFFSET 24u
#define VG_FLASH_RECORD_ZONE_LENGTH_OFFSET 25u
#define VG_FLASH_RECORD_NODE_LENGTH_OFFSET 26u
#define VG_FLASH_RECORD_KEY_OFFSET 32u
#define VG_FLASH_RECORD_KEY_CAPACITY 95u
#define VG_FLASH_RECORD_ZONE_OFFSET 127u
#define VG_FLASH_RECORD_ZONE_CAPACITY 31u
#define VG_FLASH_RECORD_NODE_OFFSET 158u
#define VG_FLASH_RECORD_NODE_CAPACITY 31u
#define VG_FLASH_RECORD_RESERVED_OFFSET 189u

#define VG_FLASH_HEADER_MAGIC_OFFSET 0u
#define VG_FLASH_HEADER_LAYOUT_VERSION_OFFSET 4u
#define VG_FLASH_HEADER_RECORD_LAYOUT_VERSION_OFFSET 5u
#define VG_FLASH_HEADER_LOGICAL_VERSION_OFFSET 6u
#define VG_FLASH_HEADER_GENERATION_OFFSET 8u
#define VG_FLASH_HEADER_SEQUENCE_HIGH_WATER_OFFSET 16u
#define VG_FLASH_HEADER_PAGE_SIZE_OFFSET 24u
#define VG_FLASH_HEADER_CAPACITY_OFFSET 26u
#define VG_FLASH_HEADER_RESERVED_OFFSET 28u

static const uint8_t g_record_magic[] = {'V', 'G', 'S', 'R'};
static const uint8_t g_header_magic[] = {'V', 'G', 'B', 'H'};

_Static_assert(VG_ACTUATOR_START_JOURNAL_MAX_IDEMPOTENCY_KEY_LEN - 1u ==
                   VG_FLASH_RECORD_KEY_CAPACITY,
               "record key field must match the logical key limit");
_Static_assert(VG_ACTUATOR_START_JOURNAL_MAX_ZONE_ID_LEN - 1u ==
                   VG_FLASH_RECORD_ZONE_CAPACITY,
               "record zone field must match the logical zone limit");
_Static_assert(VG_ACTUATOR_START_JOURNAL_MAX_NODE_ID_LEN - 1u ==
                   VG_FLASH_RECORD_NODE_CAPACITY,
               "record node field must match the logical node limit");
_Static_assert(VG_FLASH_RECORD_RESERVED_OFFSET < VG_FLASH_PAGE_PROTECTED_BYTES,
               "record reserved bytes must be CRC protected");
_Static_assert(VG_FLASH_HEADER_RESERVED_OFFSET < VG_FLASH_PAGE_PROTECTED_BYTES,
               "header reserved bytes must be CRC protected");

static void write_u16_le(uint8_t *bytes, uint16_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8u);
}

static uint16_t read_u16_le(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8u);
}

static void write_u32_le(uint8_t *bytes, uint32_t value) {
    for (size_t i = 0; i < 4u; ++i) {
        bytes[i] = (uint8_t)(value >> (i * 8u));
    }
}

static uint32_t read_u32_le(const uint8_t *bytes) {
    uint32_t value = 0;
    for (size_t i = 0; i < 4u; ++i) {
        value |= (uint32_t)bytes[i] << (i * 8u);
    }
    return value;
}

static void write_u64_le(uint8_t *bytes, uint64_t value) {
    for (size_t i = 0; i < 8u; ++i) {
        bytes[i] = (uint8_t)(value >> (i * 8u));
    }
}

static uint64_t read_u64_le(const uint8_t *bytes) {
    uint64_t value = 0;
    for (size_t i = 0; i < 8u; ++i) {
        value |= (uint64_t)bytes[i] << (i * 8u);
    }
    return value;
}

static bool bytes_are_zero(const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < length; ++i) {
        if (bytes[i] != 0u) {
            return false;
        }
    }
    return true;
}

static bool string_length_for_field(const char *value, size_t capacity, size_t *length_out) {
    if (!value || !length_out) {
        return false;
    }

    for (size_t i = 0; i <= capacity; ++i) {
        if (value[i] == '\0') {
            if (i == 0u || i > capacity) {
                return false;
            }
            *length_out = i;
            return true;
        }
    }
    return false;
}

static bool write_string_field(uint8_t *destination, size_t capacity, const char *value) {
    size_t length;
    if (!string_length_for_field(value, capacity, &length)) {
        return false;
    }
    memcpy(destination, value, length);
    return true;
}

static bool decode_string_field(const uint8_t *source, size_t capacity, uint8_t length,
                                char *destination, size_t destination_size) {
    if (length == 0u || (size_t)length > capacity || destination_size != capacity + 1u ||
        !bytes_are_zero(source + length, capacity - (size_t)length)) {
        return false;
    }

    for (size_t i = 0; i < (size_t)length; ++i) {
        if (source[i] == '\0') {
            return false;
        }
    }

    memcpy(destination, source, length);
    destination[length] = '\0';
    return true;
}

static bool page_has_valid_integrity(const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    const uint32_t stored_crc = read_u32_le(page + VG_FLASH_PAGE_CRC_OFFSET);
    const uint32_t stored_inverse = read_u32_le(page + VG_FLASH_PAGE_CRC_INVERSE_OFFSET);
    return stored_inverse == ~stored_crc &&
           stored_crc == vg_actuator_start_journal_flash_crc32(page, VG_FLASH_PAGE_PROTECTED_BYTES);
}

static void write_page_integrity(uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]) {
    const uint32_t crc = vg_actuator_start_journal_flash_crc32(page, VG_FLASH_PAGE_PROTECTED_BYTES);
    write_u32_le(page + VG_FLASH_PAGE_CRC_OFFSET, crc);
    write_u32_le(page + VG_FLASH_PAGE_CRC_INVERSE_OFFSET, ~crc);
}

uint32_t vg_actuator_start_journal_flash_crc32(const uint8_t *bytes, size_t length) {
    if (!bytes && length != 0u) {
        return 0u;
    }

    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < length; ++i) {
        crc ^= bytes[i];
        for (uint8_t bit = 0; bit < 8u; ++bit) {
            crc = (crc & 1u) != 0u ? (crc >> 1u) ^ 0xEDB88320u : crc >> 1u;
        }
    }
    return ~crc;
}

bool vg_actuator_start_journal_flash_page_is_erased(
    const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
) {
    if (!page) {
        return false;
    }

    for (size_t i = 0; i < VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE; ++i) {
        if (page[i] != 0xFFu) {
            return false;
        }
    }
    return true;
}

bool vg_actuator_start_journal_flash_encode_accepted_record(
    const vg_actuator_start_journal_flash_accepted_record_t *record,
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
) {
    if (!record || !page || !vg_actuator_start_journal_record_is_valid(&record->accepted_record) ||
        record->accepted_record.version != VG_ACTUATOR_START_JOURNAL_RECORD_VERSION) {
        return false;
    }

    memset(page, 0, VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE);
    memcpy(page + VG_FLASH_RECORD_MAGIC_OFFSET, g_record_magic, sizeof(g_record_magic));
    page[VG_FLASH_RECORD_LAYOUT_VERSION_OFFSET] = VG_ACTUATOR_START_JOURNAL_FLASH_RECORD_LAYOUT_VERSION;
    page[VG_FLASH_RECORD_LOGICAL_VERSION_OFFSET] = record->accepted_record.version;
    page[VG_FLASH_RECORD_TYPE_OFFSET] = VG_ACTUATOR_START_JOURNAL_FLASH_ACCEPTED_RECORD_TYPE;
    page[VG_FLASH_RECORD_LINE_OFFSET] = record->accepted_record.irrigation_line;
    write_u64_le(page + VG_FLASH_RECORD_SEQUENCE_OFFSET, record->sequence);
    write_u64_le(page + VG_FLASH_RECORD_ISSUED_AT_OFFSET,
                 (uint64_t)record->accepted_record.issued_at_epoch_seconds);

    size_t key_length;
    size_t zone_length;
    size_t node_length;
    if (!string_length_for_field(record->accepted_record.idempotency_key,
                                 VG_FLASH_RECORD_KEY_CAPACITY, &key_length) ||
        !string_length_for_field(record->accepted_record.zone_id,
                                 VG_FLASH_RECORD_ZONE_CAPACITY, &zone_length) ||
        !string_length_for_field(record->accepted_record.node_id,
                                 VG_FLASH_RECORD_NODE_CAPACITY, &node_length) ||
        !write_string_field(page + VG_FLASH_RECORD_KEY_OFFSET, VG_FLASH_RECORD_KEY_CAPACITY,
                            record->accepted_record.idempotency_key) ||
        !write_string_field(page + VG_FLASH_RECORD_ZONE_OFFSET, VG_FLASH_RECORD_ZONE_CAPACITY,
                            record->accepted_record.zone_id) ||
        !write_string_field(page + VG_FLASH_RECORD_NODE_OFFSET, VG_FLASH_RECORD_NODE_CAPACITY,
                            record->accepted_record.node_id)) {
        return false;
    }
    page[VG_FLASH_RECORD_KEY_LENGTH_OFFSET] = (uint8_t)key_length;
    page[VG_FLASH_RECORD_ZONE_LENGTH_OFFSET] = (uint8_t)zone_length;
    page[VG_FLASH_RECORD_NODE_LENGTH_OFFSET] = (uint8_t)node_length;
    write_page_integrity(page);
    return true;
}

vg_actuator_start_journal_flash_page_result_t
vg_actuator_start_journal_flash_decode_accepted_record(
    const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE],
    vg_actuator_start_journal_flash_accepted_record_t *record_out
) {
    if (!page || !record_out) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID;
    }
    if (vg_actuator_start_journal_flash_page_is_erased(page)) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_ERASED;
    }
    if (!page_has_valid_integrity(page) ||
        memcmp(page + VG_FLASH_RECORD_MAGIC_OFFSET, g_record_magic, sizeof(g_record_magic)) != 0) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID;
    }
    if (page[VG_FLASH_RECORD_LAYOUT_VERSION_OFFSET] != VG_ACTUATOR_START_JOURNAL_FLASH_RECORD_LAYOUT_VERSION ||
        page[VG_FLASH_RECORD_LOGICAL_VERSION_OFFSET] != VG_ACTUATOR_START_JOURNAL_RECORD_VERSION ||
        page[VG_FLASH_RECORD_TYPE_OFFSET] != VG_ACTUATOR_START_JOURNAL_FLASH_ACCEPTED_RECORD_TYPE) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED;
    }
    if (!bytes_are_zero(page + 27u, 5u) ||
        !bytes_are_zero(page + VG_FLASH_RECORD_RESERVED_OFFSET,
                        VG_FLASH_PAGE_PROTECTED_BYTES - VG_FLASH_RECORD_RESERVED_OFFSET)) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID;
    }

    vg_actuator_start_journal_flash_accepted_record_t decoded;
    memset(&decoded, 0, sizeof(decoded));
    decoded.sequence = read_u64_le(page + VG_FLASH_RECORD_SEQUENCE_OFFSET);
    decoded.accepted_record.accepted = true;
    decoded.accepted_record.version = page[VG_FLASH_RECORD_LOGICAL_VERSION_OFFSET];
    decoded.accepted_record.irrigation_line = page[VG_FLASH_RECORD_LINE_OFFSET];
    decoded.accepted_record.issued_at_epoch_seconds =
        (int64_t)read_u64_le(page + VG_FLASH_RECORD_ISSUED_AT_OFFSET);
    if (!decode_string_field(page + VG_FLASH_RECORD_KEY_OFFSET, VG_FLASH_RECORD_KEY_CAPACITY,
                             page[VG_FLASH_RECORD_KEY_LENGTH_OFFSET],
                             decoded.accepted_record.idempotency_key,
                             sizeof(decoded.accepted_record.idempotency_key)) ||
        !decode_string_field(page + VG_FLASH_RECORD_ZONE_OFFSET, VG_FLASH_RECORD_ZONE_CAPACITY,
                             page[VG_FLASH_RECORD_ZONE_LENGTH_OFFSET],
                             decoded.accepted_record.zone_id,
                             sizeof(decoded.accepted_record.zone_id)) ||
        !decode_string_field(page + VG_FLASH_RECORD_NODE_OFFSET, VG_FLASH_RECORD_NODE_CAPACITY,
                             page[VG_FLASH_RECORD_NODE_LENGTH_OFFSET],
                             decoded.accepted_record.node_id,
                             sizeof(decoded.accepted_record.node_id)) ||
        !vg_actuator_start_journal_record_is_valid(&decoded.accepted_record)) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID;
    }

    *record_out = decoded;
    return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID;
}

bool vg_actuator_start_journal_flash_encode_bank_header(
    const vg_actuator_start_journal_flash_bank_header_t *header,
    uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE]
) {
    if (!header || !page ||
        header->record_page_size != VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE ||
        header->logical_capacity != VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY) {
        return false;
    }

    memset(page, 0, VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE);
    memcpy(page + VG_FLASH_HEADER_MAGIC_OFFSET, g_header_magic, sizeof(g_header_magic));
    page[VG_FLASH_HEADER_LAYOUT_VERSION_OFFSET] = VG_ACTUATOR_START_JOURNAL_FLASH_BANK_HEADER_LAYOUT_VERSION;
    page[VG_FLASH_HEADER_RECORD_LAYOUT_VERSION_OFFSET] = VG_ACTUATOR_START_JOURNAL_FLASH_RECORD_LAYOUT_VERSION;
    page[VG_FLASH_HEADER_LOGICAL_VERSION_OFFSET] = VG_ACTUATOR_START_JOURNAL_RECORD_VERSION;
    write_u64_le(page + VG_FLASH_HEADER_GENERATION_OFFSET, header->generation);
    write_u64_le(page + VG_FLASH_HEADER_SEQUENCE_HIGH_WATER_OFFSET,
                 header->sequence_high_water_mark);
    write_u16_le(page + VG_FLASH_HEADER_PAGE_SIZE_OFFSET, header->record_page_size);
    write_u16_le(page + VG_FLASH_HEADER_CAPACITY_OFFSET, header->logical_capacity);
    write_page_integrity(page);
    return true;
}

vg_actuator_start_journal_flash_page_result_t
vg_actuator_start_journal_flash_decode_bank_header(
    const uint8_t page[VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE],
    vg_actuator_start_journal_flash_bank_header_t *header_out
) {
    if (!page || !header_out) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID;
    }
    if (vg_actuator_start_journal_flash_page_is_erased(page)) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_ERASED;
    }
    if (!page_has_valid_integrity(page) ||
        memcmp(page + VG_FLASH_HEADER_MAGIC_OFFSET, g_header_magic, sizeof(g_header_magic)) != 0) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID;
    }
    if (page[VG_FLASH_HEADER_LAYOUT_VERSION_OFFSET] != VG_ACTUATOR_START_JOURNAL_FLASH_BANK_HEADER_LAYOUT_VERSION ||
        page[VG_FLASH_HEADER_RECORD_LAYOUT_VERSION_OFFSET] != VG_ACTUATOR_START_JOURNAL_FLASH_RECORD_LAYOUT_VERSION ||
        page[VG_FLASH_HEADER_LOGICAL_VERSION_OFFSET] != VG_ACTUATOR_START_JOURNAL_RECORD_VERSION) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED;
    }
    if (!bytes_are_zero(page + 7u, 1u) ||
        !bytes_are_zero(page + VG_FLASH_HEADER_RESERVED_OFFSET,
                        VG_FLASH_PAGE_PROTECTED_BYTES - VG_FLASH_HEADER_RESERVED_OFFSET)) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_INVALID;
    }

    vg_actuator_start_journal_flash_bank_header_t decoded = {
        .generation = read_u64_le(page + VG_FLASH_HEADER_GENERATION_OFFSET),
        .sequence_high_water_mark =
            read_u64_le(page + VG_FLASH_HEADER_SEQUENCE_HIGH_WATER_OFFSET),
        .record_page_size = read_u16_le(page + VG_FLASH_HEADER_PAGE_SIZE_OFFSET),
        .logical_capacity = read_u16_le(page + VG_FLASH_HEADER_CAPACITY_OFFSET),
    };
    if (decoded.record_page_size != VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_SIZE ||
        decoded.logical_capacity != VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY) {
        return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_UNSUPPORTED;
    }

    *header_out = decoded;
    return VG_ACTUATOR_START_JOURNAL_FLASH_PAGE_VALID;
}
