cmake_minimum_required(VERSION 3.13)

include(${CMAKE_CURRENT_LIST_DIR}/../cmake/select_arm_gnu_toolchain.cmake)

if(NOT DEFINED ENV{PICO_SDK_PATH})
  get_filename_component(DEFAULT_PICO_SDK_PATH "${CMAKE_CURRENT_LIST_DIR}/../pico-sdk" ABSOLUTE)
  set(ENV{PICO_SDK_PATH} "${DEFAULT_PICO_SDK_PATH}")
endif()

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(victory_garden_pico_w_sensor_node C CXX ASM)

option(VG_BUNDLED_BUILD "Build distributable firmware without config_local.h" OFF)
option(VG_ENABLE_LORA_TRANSPORT "Enable sensor-node LoRa transport runtime scaffolding" OFF)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(pico_w_sensor_node
    src/main.c
    src/ads1115.c
    src/i2c1_bus.c
    src/lora_command_runtime.c
    src/lora_protocol.c
    src/lora_transport.c
    src/mqtt_node.c
    src/node_config.c
    src/sensors.c
    src/sensor_state_payload.c
    src/sht40.c
    src/time_sync.c
    src/topics.c
    src/wifi.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/json_lite.c
)

target_include_directories(pico_w_sensor_node PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
    ${CMAKE_CURRENT_LIST_DIR}/../shared
)

if(VG_BUNDLED_BUILD)
    target_compile_definitions(pico_w_sensor_node PRIVATE VG_BUNDLED_BUILD=1)
endif()

if(VG_ENABLE_LORA_TRANSPORT)
    target_compile_definitions(pico_w_sensor_node PRIVATE VG_ENABLE_LORA_TRANSPORT=true)
endif()

target_link_libraries(pico_w_sensor_node
    pico_stdlib
    pico_aon_timer
    pico_cyw43_arch_lwip_threadsafe_background
    pico_lwip_mqtt
    pico_lwip_sntp
    hardware_flash
    hardware_i2c
    hardware_uart
    hardware_sync
    hardware_xosc
)

if(PICO_RP2040)
    target_link_libraries(pico_w_sensor_node hardware_rtc)
endif()

pico_enable_stdio_uart(pico_w_sensor_node 0)
pico_enable_stdio_usb(pico_w_sensor_node 1)

pico_add_extra_outputs(pico_w_sensor_node)

# This deliberately small, RP2040-only feasibility target proves an internal
# ROSC-timed low-power wake foundation for the future LoRa-primary runtime. It
# is excluded from normal builds and shares no CYW43, lwIP, MQTT, or Wi-Fi
# runtime sources with the established Wi-Fi/MQTT firmware above.
add_executable(pico_w_sensor_node_lora_low_power EXCLUDE_FROM_ALL
    src/lora_low_power_main.c
    src/ads1115.c
    src/i2c1_bus.c
    src/lora_protocol.c
    src/lora_transport.c
    src/node_config.c
    src/sensors.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/json_lite.c
)

target_include_directories(pico_w_sensor_node_lora_low_power PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
    ${CMAKE_CURRENT_LIST_DIR}/../shared
)

target_link_libraries(pico_w_sensor_node_lora_low_power
    pico_stdlib
    hardware_clocks
    hardware_gpio
    hardware_i2c
    hardware_uart
    hardware_flash
    hardware_xosc
)

# The feasibility proof logs across low-power clock transitions. Do not discard those
# logs merely because an automated USB CDC reader cannot assert DTR.
target_compile_definitions(pico_w_sensor_node_lora_low_power PRIVATE
    PICO_STDIO_USB_CONNECTION_WITHOUT_DTR=1
)

pico_enable_stdio_uart(pico_w_sensor_node_lora_low_power 0)
pico_enable_stdio_usb(pico_w_sensor_node_lora_low_power 1)

pico_add_extra_outputs(pico_w_sensor_node_lora_low_power)
