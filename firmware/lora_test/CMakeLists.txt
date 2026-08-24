cmake_minimum_required(VERSION 3.13)

include(${CMAKE_CURRENT_LIST_DIR}/../cmake/select_arm_gnu_toolchain.cmake)

if(NOT DEFINED ENV{PICO_SDK_PATH})
  get_filename_component(DEFAULT_PICO_SDK_PATH "${CMAKE_CURRENT_LIST_DIR}/../pico-sdk" ABSOLUTE)
  set(ENV{PICO_SDK_PATH} "${DEFAULT_PICO_SDK_PATH}")
endif()

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(lora_test C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(lora_test
    src/main.c
    ${CMAKE_CURRENT_LIST_DIR}/../shared/json_lite.c
)

target_include_directories(lora_test PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/../shared
)

target_link_libraries(lora_test
    pico_stdlib
    hardware_uart
)

target_compile_definitions(lora_test PRIVATE
    PICO_STDIO_USB_CONNECTION_WITHOUT_DTR=1
)

pico_enable_stdio_usb(lora_test 1)
pico_enable_stdio_uart(lora_test 0)

pico_add_extra_outputs(lora_test)
