#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_source(void) {
    FILE *file = fopen(VG_DEDICATED_MQTT_SOURCE, "rb");
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
    const char *shutdown = strstr(source, "static void actuator_stop_with_status");
    const char *gpio_off = shutdown ? strstr(shutdown, "actuator_set_line_output(node, irrigation_line, false);") : NULL;
    const char *status = gpio_off ? strstr(gpio_off, "mqtt_publish_actuator_status_now(") : NULL;
    const char *cleanup = status ? strstr(status, "memset(run, 0, sizeof(*run));") : NULL;
    const char *receive_failure = strstr(source, "static void fail_closed_retained_topology_receive");
    const char *invalid_stop = receive_failure ? strstr(receive_failure, "stop_runs_invalidated_by_topology(node, NULL, 0);") : NULL;
    const char *clear = invalid_stop ? strstr(invalid_stop, "clear_actuator_topology(node);") : NULL;
    const char *handler = strstr(source, "static void handle_actuator_config_message");
    const char *invalid_failure = handler ? strstr(handler, "fail_closed_retained_topology_receive(node, \"invalid actuator config\")") : NULL;
    const char *valid_stop = invalid_failure ? strstr(invalid_failure, "stop_runs_invalidated_by_topology(") : NULL;
    const char *replace = valid_stop ? strstr(valid_stop, "memcpy(node->assignments, candidate_assignments") : NULL;

    assert(shutdown != NULL && gpio_off != NULL && status != NULL && cleanup != NULL);
    assert(gpio_off < status);
    assert(status < cleanup);
    assert(handler != NULL && receive_failure != NULL && invalid_stop != NULL && clear != NULL && invalid_failure != NULL);
    assert(invalid_stop < clear);
    assert(valid_stop != NULL && replace != NULL);
    assert(valid_stop < replace);

    free(source);
    puts("dedicated_actuator_topology_update_order_tests: passed");
    return 0;
}
