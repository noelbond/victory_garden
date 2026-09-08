#pragma once

// lora_protocol uses node_config_t but does not access Pico flash. This small
// declaration lets the host test compile config.h without emulating the SDK.
#define PICO_FLASH_SIZE_BYTES (2u * 1024u * 1024u)
#define FLASH_SECTOR_SIZE 4096u
