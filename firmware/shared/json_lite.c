#include "json_lite.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *skip_json_whitespace(const char *cursor) {
    while (cursor && (*cursor == ' ' || *cursor == '\n' || *cursor == '\r' || *cursor == '\t')) {
        ++cursor;
    }
    return cursor;
}

// Finds "key" in payload, then returns a pointer just past the following ':',
// with any whitespace before the value skipped. NULL if the key or its colon
// isn't found.
static const char *json_value_start(const char *payload, const char *key) {
    char key_pattern[64];
    snprintf(key_pattern, sizeof(key_pattern), "\"%s\"", key);
    const char *start = strstr(payload, key_pattern);
    if (!start) {
        return NULL;
    }
    start += strlen(key_pattern);
    start = strchr(start, ':');
    if (!start) {
        return NULL;
    }
    return skip_json_whitespace(start + 1);
}

bool decode_json_string(const char *start, char *out, size_t out_size, const char **end_out) {
    size_t out_len = 0;
    const char *cursor = start;

    if (!start || !out || out_size == 0) {
        return false;
    }

    while (*cursor != '\0') {
        char ch = *cursor++;
        if (ch == '"') {
            out[out_len] = '\0';
            if (end_out) {
                *end_out = cursor;
            }
            return true;
        }

        if (ch == '\\') {
            ch = *cursor++;
            switch (ch) {
                case '"':
                case '\\':
                case '/':
                    break;
                case 'b':
                    ch = '\b';
                    break;
                case 'f':
                    ch = '\f';
                    break;
                case 'n':
                    ch = '\n';
                    break;
                case 'r':
                    ch = '\r';
                    break;
                case 't':
                    ch = '\t';
                    break;
                default:
                    return false;
            }
        }

        if (out_len + 1 < out_size) {
            out[out_len++] = ch;
        }
    }

    return false;
}

bool extract_json_string(const char *payload, const char *key, char *out, size_t out_size) {
    const char *start = json_value_start(payload, key);
    if (!start || *start != '"') {
        return false;
    }
    return decode_json_string(start + 1, out, out_size, NULL);
}

bool extract_json_bool(const char *payload, const char *key, bool *out) {
    const char *start = json_value_start(payload, key);
    if (!start) {
        return false;
    }
    if (strncmp(start, "true", 4) == 0) {
        *out = true;
        return true;
    }
    if (strncmp(start, "false", 5) == 0) {
        *out = false;
        return true;
    }
    return false;
}

bool extract_json_int(const char *payload, const char *key, int *out) {
    const char *start = json_value_start(payload, key);
    if (!start) {
        return false;
    }
    if ((*start < '0' || *start > '9') && *start != '-') {
        return false;
    }
    *out = (int)strtol(start, NULL, 10);
    return true;
}

bool extract_json_float(const char *payload, const char *key, float *out) {
    const char *start = json_value_start(payload, key);
    if (!start) {
        return false;
    }
    *out = strtof(start, NULL);
    return true;
}

bool extract_json_array_start(const char *payload, const char *key, const char **array_start_out) {
    const char *start = json_value_start(payload, key);
    if (!start || *start != '[') {
        return false;
    }
    *array_start_out = start + 1;
    return true;
}

bool next_json_object(const char **cursor_in_out, char *out, size_t out_size) {
    const char *cursor = *cursor_in_out;
    const char *object_start = NULL;
    bool in_string = false;
    bool escaped = false;
    int depth = 0;

    while (*cursor != '\0' && *cursor != ']') {
        if (*cursor == '{') {
            object_start = cursor;
            break;
        }
        cursor++;
    }
    if (!object_start) {
        *cursor_in_out = cursor;
        return false;
    }

    for (; *cursor != '\0'; ++cursor) {
        char ch = *cursor;
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }

        if (ch == '"') {
            in_string = true;
        } else if (ch == '{') {
            depth++;
        } else if (ch == '}') {
            depth--;
            if (depth == 0) {
                size_t len = (size_t)(cursor - object_start + 1);
                if (len >= out_size) {
                    len = out_size - 1;
                }
                memcpy(out, object_start, len);
                out[len] = '\0';
                *cursor_in_out = cursor + 1;
                return true;
            }
        }
    }

    *cursor_in_out = cursor;
    return false;
}
