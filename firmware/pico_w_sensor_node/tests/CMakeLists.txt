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
