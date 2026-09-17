#pragma once

// Rails serializes retained actuator-config/v1 with compact JSON. Its legal
// maximum for the dedicated controller is 1,618 bytes:
//
//   128 bytes: envelope with an empty nodes array, including the 20-byte UTC
//              ISO-8601 config_version emitted by Time#iso8601;
// 1,479 bytes: twelve route objects with maximum legal identities. A Node ID
//              is a 27-byte package plus -chN, and a Zone ID is 31 bytes.
//              The firmware-visible identity alphabet is [A-Za-z0-9_-], so
//              neither value needs JSON escaping. Lines 1..9 are 123 bytes
//              each and lines 10..12 are 124 bytes each;
//    11 bytes: commas between the twelve route objects.
//
// 128 + (9 * 123) + (3 * 124) + 11 = 1,618.
//
// The 4,096-byte storage buffer accepts 4,095 payload bytes, leaving exactly
// 2,477 bytes above the 1,618-byte legal maximum while retaining one byte for
// the local NUL terminator.
#define VG_DEDICATED_ACTUATOR_TOPOLOGY_LEGAL_MAX_SERIALIZED_BYTES 1618u
#define VG_DEDICATED_ACTUATOR_MQTT_RX_PAYLOAD_STORAGE_BYTES 4096u
#define VG_DEDICATED_ACTUATOR_MQTT_RX_MAX_PAYLOAD_BYTES \
    (VG_DEDICATED_ACTUATOR_MQTT_RX_PAYLOAD_STORAGE_BYTES - 1u)
