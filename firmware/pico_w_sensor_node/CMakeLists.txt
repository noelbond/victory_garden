cmake_minimum_required(VERSION 3.13)

include(${CMAKE_CURRENT_LIST_DIR}/../cmake/select_arm_gnu_toolchain.cmake)

if(NOT DEFINED ENV{PICO_SDK_PATH})
  get_filename_component(DEFAULT_PICO_SDK_PATH "${CMAKE_CURRENT_LIST_DIR}/../pico-sdk" ABSOLUTE)
  set(ENV{PICO_SDK_PATH} "${DEFAULT_PICO_SDK_PATH}")
endif()

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(victory_garden_pico_w_sensor_node C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(pico_w_sensor_node
    src/main.c
    src/mqtt_node.c
    src/node_config.c
    src/seesaw.c
    src/sensors.c
    src/time_sync.c
    src/topics.c
    src/wifi.c
)

target_include_directories(pico_w_sensor_node PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
)

target_link_libraries(pico_w_sensor_node
    pico_stdlib
    pico_aon_timer
    pico_cyw43_arch_lwip_threadsafe_background
    pico_lwip_mqtt
    pico_lwip_sntp
    hardware_flash
    hardware_i2c
    hardware_sync
    hardware_xosc
)

if(PICO_RP2040)
    target_link_libraries(pico_w_sensor_node hardware_rtc)
endif()

pico_enable_stdio_uart(pico_w_sensor_node 0)
pico_enable_stdio_usb(pico_w_sensor_node 1)

pico_add_extra_outputs(pico_w_sensor_node)
