cmake_minimum_required(VERSION 3.16)

project(victory_garden_sensor_host_tests C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

enable_testing()

add_executable(lora_scheduler_tests
    test_lora_scheduler.c
    ../src/lora_scheduler.c
)

target_include_directories(lora_scheduler_tests PRIVATE
    ../src
)

add_test(NAME lora_scheduler_tests COMMAND lora_scheduler_tests)

add_executable(lora_protocol_tests
    test_lora_protocol.c
    ../src/lora_protocol.c
    ../../shared/json_lite.c
)

target_include_directories(lora_protocol_tests PRIVATE
    include
    ../src
    ../../shared
)

add_test(NAME lora_protocol_tests COMMAND lora_protocol_tests)

add_executable(sensor_provisioning_channels_tests
    test_sensor_provisioning_channels.c
    ../src/node_config.c
    ../../shared/json_lite.c
)

target_include_directories(sensor_provisioning_channels_tests PRIVATE
    include
    ../src
    ../../shared
)

add_test(NAME sensor_provisioning_channels_tests COMMAND sensor_provisioning_channels_tests)

add_executable(sensor_provisioning_ack_tests
    test_sensor_provisioning_ack.c
)

target_compile_definitions(sensor_provisioning_ack_tests PRIVATE
    VG_SENSOR_MAIN_SOURCE="${CMAKE_CURRENT_LIST_DIR}/../src/main.c"
)

add_test(NAME sensor_provisioning_ack_tests COMMAND sensor_provisioning_ack_tests)
