cmake_minimum_required(VERSION 3.13)

include(${CMAKE_CURRENT_LIST_DIR}/../cmake/select_arm_gnu_toolchain.cmake)

if(NOT DEFINED ENV{PICO_SDK_PATH})
  get_filename_component(DEFAULT_PICO_SDK_PATH "${CMAKE_CURRENT_LIST_DIR}/../pico-sdk" ABSOLUTE)
  set(ENV{PICO_SDK_PATH} "${DEFAULT_PICO_SDK_PATH}")
endif()

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(victory_garden_pico_w_combined_node C CXX ASM)

option(VG_BUNDLED_BUILD "Build distributable firmware without config_local.h" OFF)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(pico_w_combined_node
    src/main.c
    src/ads1115.c
    src/i2c_bus.c
    src/mqtt_node.c
    src/node_config.c
    src/sensors.c
    src/sht40.c
    src/time_sync.c
    src/topics.c
    src/wifi.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/json_lite.c
)

target_include_directories(pico_w_combined_node PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
    ${CMAKE_CURRENT_LIST_DIR}/../shared
)

if(VG_BUNDLED_BUILD)
    target_compile_definitions(pico_w_combined_node PRIVATE VG_BUNDLED_BUILD=1)
endif()

target_link_libraries(pico_w_combined_node
    pico_stdlib
    pico_cyw43_arch_lwip_threadsafe_background
    pico_lwip_mqtt
    pico_lwip_sntp
    hardware_flash
    hardware_i2c
    hardware_sync
)

pico_enable_stdio_uart(pico_w_combined_node 0)
pico_enable_stdio_usb(pico_w_combined_node 1)

pico_add_extra_outputs(pico_w_combined_node)

add_executable(pico_w_combined_relay_sequence_test
    src/relay_sequence_test.c
)

target_link_libraries(pico_w_combined_relay_sequence_test
    pico_stdlib
    hardware_gpio
)

pico_enable_stdio_uart(pico_w_combined_relay_sequence_test 0)
pico_enable_stdio_usb(pico_w_combined_relay_sequence_test 1)

pico_add_extra_outputs(pico_w_combined_relay_sequence_test)

add_executable(pico_w_combined_relay_combo_test
    src/relay_combo_test.c
)

target_link_libraries(pico_w_combined_relay_combo_test
    pico_stdlib
    hardware_gpio
)

pico_enable_stdio_uart(pico_w_combined_relay_combo_test 0)
pico_enable_stdio_usb(pico_w_combined_relay_combo_test 1)

pico_add_extra_outputs(pico_w_combined_relay_combo_test)

add_executable(pico_w_combined_sensor_smoke_test
    src/sensor_smoke_test.c
    src/ads1115.c
    src/i2c_bus.c
    src/node_config.c
    src/sensors.c
    src/sht40.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/json_lite.c
)

target_include_directories(pico_w_combined_sensor_smoke_test PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
    ${CMAKE_CURRENT_LIST_DIR}/../shared
)

if(VG_BUNDLED_BUILD)
    target_compile_definitions(pico_w_combined_sensor_smoke_test PRIVATE VG_BUNDLED_BUILD=1)
endif()

target_link_libraries(pico_w_combined_sensor_smoke_test
    pico_stdlib
    hardware_flash
    hardware_i2c
    hardware_sync
)

pico_enable_stdio_uart(pico_w_combined_sensor_smoke_test 0)
pico_enable_stdio_usb(pico_w_combined_sensor_smoke_test 1)

pico_add_extra_outputs(pico_w_combined_sensor_smoke_test)
