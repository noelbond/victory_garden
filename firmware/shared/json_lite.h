#pragma once

#include <stdbool.h>
#include <stddef.h>

// Minimal hand-rolled JSON reader shared by the sensor and actuator firmware.
// Payloads are flat, known-shape objects (MQTT config/command messages), so
// this intentionally does not handle arbitrary/nested JSON beyond the small
// array-of-objects support next_json_object provides for the ADS1115 channel
// list.

bool decode_json_string(const char *start, char *out, size_t out_size, const char **end_out);
bool extract_json_string(const char *payload, const char *key, char *out, size_t out_size);
bool extract_json_bool(const char *payload, const char *key, bool *out);
bool extract_json_int(const char *payload, const char *key, int *out);
bool extract_json_float(const char *payload, const char *key, float *out);
bool extract_json_array_start(const char *payload, const char *key, const char **array_start_out);
bool next_json_object(const char **cursor_in_out, char *out, size_t out_size);
