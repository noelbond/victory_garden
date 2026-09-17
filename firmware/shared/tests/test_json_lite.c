#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "json_lite.h"

static void fill(char *out, size_t count, char value) {
    memset(out, value, count);
    out[count] = '\0';
}

static void test_exact_boundary_accepts_31_decoded_bytes(void) {
    char source[33];
    char out[32] = {0};
    memset(source, 'a', 31);
    source[31] = '"';
    source[32] = '\0';

    assert(decode_json_string(source, out, sizeof(out), NULL));
    assert(strlen(out) == 31);
    assert(memcmp(out, source, 31) == 0);
}

static void test_one_byte_over_boundary_rejects_and_clears_output(void) {
    char source[34];
    char out[32];
    memset(source, 'a', 32);
    source[32] = '"';
    source[33] = '\0';
    memset(out, 'x', sizeof(out));

    assert(!decode_json_string(source, out, sizeof(out), NULL));
    assert(out[0] == '\0');
}

static void test_long_prefix_cannot_alias_valid_identity(void) {
    char valid[32];
    char long_identity[37];
    char out[32] = {0};
    fill(valid, 31, 'n');
    memcpy(long_identity, valid, 31);
    memcpy(long_identity + 31, "more\"", 6);

    assert(!decode_json_string(long_identity, out, sizeof(out), NULL));
    assert(out[0] == '\0');
    assert(strcmp(out, valid) != 0);
}

static void test_escaped_decoded_boundary(void) {
    char source[96] = {0};
    char out[32] = {0};
    size_t length = 0;

    for (size_t index = 0; index < 31; ++index) {
        source[length++] = '\\';
        source[length++] = '"';
    }
    source[length++] = '"';
    source[length] = '\0';
    assert(decode_json_string(source, out, sizeof(out), NULL));
    assert(strlen(out) == 31);
    for (size_t index = 0; index < 31; ++index) {
        assert(out[index] == '"');
    }

    length = 0;
    for (size_t index = 0; index < 32; ++index) {
        source[length++] = '\\';
        source[length++] = '"';
    }
    source[length++] = '"';
    source[length] = '\0';
    assert(!decode_json_string(source, out, sizeof(out), NULL));
    assert(out[0] == '\0');
}

static void test_malformed_escape_remains_rejected(void) {
    char out[32] = {0};
    assert(!decode_json_string("bad\\u1234\"", out, sizeof(out), NULL));
    assert(out[0] == '\0');
}

int main(void) {
    test_exact_boundary_accepts_31_decoded_bytes();
    test_one_byte_over_boundary_rejects_and_clears_output();
    test_long_prefix_cannot_alias_valid_identity();
    test_escaped_decoded_boundary();
    test_malformed_escape_remains_rejected();
    puts("json_lite_tests: passed");
    return 0;
}
