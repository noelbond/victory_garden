#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_source(void) {
    FILE *file = fopen(VG_SENSOR_MAIN_SOURCE, "rb");
    assert(file != NULL);
    assert(fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file);
    assert(length > 0);
    rewind(file);

    char *source = calloc((size_t)length + 1u, 1u);
    assert(source != NULL);
    assert(fread(source, 1, (size_t)length, file) == (size_t)length);
    assert(fclose(file) == 0);
    return source;
}

int main(void) {
    char *source = read_source();
    const char *ack = strstr(source, "VG_PROVISION_OK");
    const char *channel0 = ack ? strstr(ack, "config->channel_node_id[0]") : NULL;
    const char *channel1 = channel0 ? strstr(channel0, "config->channel_node_id[1]") : NULL;
    const char *channel2 = channel1 ? strstr(channel1, "config->channel_node_id[2]") : NULL;
    const char *channel3 = channel2 ? strstr(channel2, "config->channel_node_id[3]") : NULL;

    assert(ack != NULL);
    assert(strstr(ack, "\\\"channels\\\":[\\\"%s\\\",\\\"%s\\\",\\\"%s\\\",\\\"%s\\\"]") != NULL);
    assert(channel0 != NULL && channel1 != NULL && channel2 != NULL && channel3 != NULL);
    assert(channel0 < channel1 && channel1 < channel2 && channel2 < channel3);

    free(source);
    puts("sensor_provisioning_ack_tests: passed");
    return 0;
}
