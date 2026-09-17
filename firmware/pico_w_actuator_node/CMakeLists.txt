cmake_minimum_required(VERSION 3.13)

include(${CMAKE_CURRENT_LIST_DIR}/../cmake/select_arm_gnu_toolchain.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/../cmake/reserve_actuator_persistent_flash.cmake)

if(NOT DEFINED ENV{PICO_SDK_PATH})
  get_filename_component(DEFAULT_PICO_SDK_PATH "${CMAKE_CURRENT_LIST_DIR}/../pico-sdk" ABSOLUTE)
  set(ENV{PICO_SDK_PATH} "${DEFAULT_PICO_SDK_PATH}")
endif()

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(victory_garden_pico_w_actuator_node C CXX ASM)

option(VG_BUNDLED_BUILD "Build distributable firmware without config_local.h" OFF)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(pico_w_actuator_node
    src/dedicated_actuator_journal_admission.c
    src/dedicated_actuator_journal_boot.c
    src/dedicated_actuator_journal_maintenance.c
    src/dedicated_actuator_journal_persistence.c
    src/dedicated_actuator_journal_runtime_state.c
    src/dedicated_actuator_topology_transition.c
    src/main.c
    src/mqtt_node.c
    src/node_config.c
    src/time_sync.c
    src/topics.c
    src/wifi.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_command_freshness.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_command_guard.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_start_runtime_guard.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_flash_mutation_policy.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_journal_flash_region.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_start_journal.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_start_journal_flash_codec.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_start_journal_storage.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/pico_actuator_journal_flash.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/actuator_topology.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/json_lite.c
)

target_include_directories(pico_w_actuator_node PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
    ${CMAKE_CURRENT_LIST_DIR}/../shared
)

if(VG_BUNDLED_BUILD)
    target_compile_definitions(pico_w_actuator_node PRIVATE VG_BUNDLED_BUILD=1)
endif()

target_link_libraries(pico_w_actuator_node
    pico_stdlib
    pico_cyw43_arch_lwip_threadsafe_background
    pico_lwip_mqtt
    pico_lwip_sntp
    pico_flash
    hardware_flash
    hardware_sync
)

pico_enable_stdio_uart(pico_w_actuator_node 0)
pico_enable_stdio_usb(pico_w_actuator_node 1)

vg_reserve_actuator_persistent_flash(pico_w_actuator_node)

pico_add_extra_outputs(pico_w_actuator_node)

add_executable(pico_w_actuator_relay_smoke_test
    src/relay_smoke_test.c
)

target_link_libraries(pico_w_actuator_relay_smoke_test
    pico_stdlib
    hardware_gpio
)

pico_enable_stdio_uart(pico_w_actuator_relay_smoke_test 0)
pico_enable_stdio_usb(pico_w_actuator_relay_smoke_test 1)

pico_add_extra_outputs(pico_w_actuator_relay_smoke_test)
