#pragma once

#include <stddef.h>
#include <stdint.h>

#define FLASH_SECTOR_SIZE 4096u
#define PICO_FLASH_SIZE_BYTES (2u * 1024u * 1024u)

void flash_range_erase(uint32_t flash_offs, size_t count);
void flash_range_program(uint32_t flash_offs, const uint8_t *data, size_t count);
