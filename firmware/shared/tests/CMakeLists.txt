cmake_minimum_required(VERSION 3.16)

project(victory_garden_actuator_topology_host_tests C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_compile_options(-Wall -Wextra -Werror)

enable_testing()

add_executable(json_lite_tests
    test_json_lite.c
    ../json_lite.c
)

target_include_directories(json_lite_tests PRIVATE
    ..
)

add_test(NAME json_lite_tests COMMAND json_lite_tests)

add_executable(actuator_topology_tests
    test_actuator_topology.c
    ../actuator_topology.c
    ../json_lite.c
)

target_include_directories(actuator_topology_tests PRIVATE
    ..
)

target_compile_definitions(actuator_topology_tests PRIVATE
    VG_FIRMWARE_SAFE_IDENTITY_FIXTURE="${CMAKE_CURRENT_LIST_DIR}/../../../contracts/examples/actuator-config-firmware-safe-identity-v1.json"
)

add_test(NAME actuator_topology_tests COMMAND actuator_topology_tests)

add_executable(actuator_command_guard_tests
    test_actuator_command_guard.c
    ../actuator_command_guard.c
)

target_include_directories(actuator_command_guard_tests PRIVATE
    ..
)

add_test(NAME actuator_command_guard_tests COMMAND actuator_command_guard_tests)

add_executable(actuator_start_runtime_guard_tests
    test_actuator_start_runtime_guard.c
    ../actuator_start_runtime_guard.c
    ../json_lite.c
)

target_include_directories(actuator_start_runtime_guard_tests PRIVATE
    ..
)

add_test(NAME actuator_start_runtime_guard_tests COMMAND actuator_start_runtime_guard_tests)

add_executable(actuator_start_journal_tests
    test_actuator_start_journal.c
    ../actuator_start_journal.c
    ../actuator_command_freshness.c
)

target_include_directories(actuator_start_journal_tests PRIVATE
    ..
)

add_test(NAME actuator_start_journal_tests COMMAND actuator_start_journal_tests)

add_executable(actuator_command_freshness_tests
    test_actuator_command_freshness.c
    ../actuator_command_freshness.c
)

target_include_directories(actuator_command_freshness_tests PRIVATE
    ..
)

add_test(NAME actuator_command_freshness_tests COMMAND actuator_command_freshness_tests)

add_executable(actuator_start_journal_flash_codec_tests
    test_actuator_start_journal_flash_codec.c
    ../actuator_start_journal_flash_codec.c
    ../actuator_start_journal.c
    ../actuator_command_freshness.c
)

target_include_directories(actuator_start_journal_flash_codec_tests PRIVATE
    ..
)

add_test(NAME actuator_start_journal_flash_codec_tests COMMAND actuator_start_journal_flash_codec_tests)

add_executable(actuator_start_journal_storage_tests
    test_actuator_start_journal_storage.c
    simulated_flash_backend.c
    ../actuator_start_journal_storage.c
    ../actuator_start_journal_flash_codec.c
    ../actuator_start_journal.c
    ../actuator_command_freshness.c
)

target_include_directories(actuator_start_journal_storage_tests PRIVATE
    ..
    .
)

add_test(NAME actuator_start_journal_storage_tests COMMAND actuator_start_journal_storage_tests)

add_executable(actuator_journal_flash_region_tests
    test_actuator_journal_flash_region.c
    ../actuator_journal_flash_region.c
)

target_include_directories(actuator_journal_flash_region_tests PRIVATE
    ..
)

add_test(NAME actuator_journal_flash_region_tests COMMAND actuator_journal_flash_region_tests)

add_executable(actuator_flash_mutation_policy_tests
    test_actuator_flash_mutation_policy.c
    ../actuator_flash_mutation_policy.c
)

target_include_directories(actuator_flash_mutation_policy_tests PRIVATE
    ..
)

add_test(NAME actuator_flash_mutation_policy_tests COMMAND actuator_flash_mutation_policy_tests)

add_test(NAME actuator_persistent_flash_tail_exact_boundary_tests
    COMMAND ${CMAKE_COMMAND}
        -DVG_LABEL=exact-boundary
        -DVG_FLASH_SIZE_BYTES=2097152
        -DVG_PROTECTED_TAIL_BYTES=28672
        -DVG_IMAGE_END=0x101F9000
        -P ${CMAKE_CURRENT_LIST_DIR}/../../cmake/check_actuator_persistent_flash_tail.cmake
)

add_test(NAME actuator_persistent_flash_tail_overlap_tests
    COMMAND ${CMAKE_COMMAND}
        -DVG_LABEL=synthetic-overlap
        -DVG_FLASH_SIZE_BYTES=2097152
        -DVG_PROTECTED_TAIL_BYTES=28672
        -DVG_IMAGE_END=0x101F9001
        -P ${CMAKE_CURRENT_LIST_DIR}/../../cmake/check_actuator_persistent_flash_tail.cmake
)
set_tests_properties(actuator_persistent_flash_tail_overlap_tests PROPERTIES WILL_FAIL TRUE)
