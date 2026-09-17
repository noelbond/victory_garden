cmake_minimum_required(VERSION 3.16)

project(victory_garden_dedicated_actuator_journal_boot_tests C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra -Werror)

enable_testing()

add_executable(dedicated_actuator_journal_runtime_state_tests
    test_dedicated_actuator_journal_runtime_state.c
    ../src/dedicated_actuator_journal_runtime_state.c
)

target_include_directories(dedicated_actuator_journal_runtime_state_tests PRIVATE
    ../src
    ../../shared
)

add_test(NAME dedicated_actuator_journal_runtime_state_tests
         COMMAND dedicated_actuator_journal_runtime_state_tests)

add_executable(dedicated_actuator_journal_maintenance_tests
    test_dedicated_actuator_journal_maintenance.c
    ../../shared/tests/simulated_flash_backend.c
    ../src/dedicated_actuator_journal_maintenance.c
    ../src/dedicated_actuator_journal_runtime_state.c
    ../../shared/actuator_start_journal_storage.c
    ../../shared/actuator_start_journal_flash_codec.c
    ../../shared/actuator_start_journal.c
    ../../shared/actuator_command_freshness.c
)

target_include_directories(dedicated_actuator_journal_maintenance_tests PRIVATE
    ../src
    ../../shared
    ../../shared/tests
)

add_test(NAME dedicated_actuator_journal_maintenance_tests
         COMMAND dedicated_actuator_journal_maintenance_tests)

add_executable(dedicated_actuator_journal_admission_tests
    test_dedicated_actuator_journal_admission.c
    ../src/dedicated_actuator_journal_admission.c
    ../src/dedicated_actuator_journal_runtime_state.c
    ../../shared/actuator_start_journal.c
    ../../shared/actuator_command_freshness.c
)

target_include_directories(dedicated_actuator_journal_admission_tests PRIVATE
    ../src
    ../../shared
)

add_test(NAME dedicated_actuator_journal_admission_tests
         COMMAND dedicated_actuator_journal_admission_tests)

add_executable(dedicated_actuator_journal_persistence_tests
    test_dedicated_actuator_journal_persistence.c
    ../../shared/tests/simulated_flash_backend.c
    ../src/dedicated_actuator_journal_admission.c
    ../src/dedicated_actuator_journal_persistence.c
    ../src/dedicated_actuator_journal_runtime_state.c
    ../../shared/actuator_command_freshness.c
    ../../shared/actuator_flash_mutation_policy.c
    ../../shared/actuator_start_journal.c
    ../../shared/actuator_start_journal_flash_codec.c
    ../../shared/actuator_start_journal_storage.c
)

target_include_directories(dedicated_actuator_journal_persistence_tests PRIVATE
    ../src
    ../../shared
    ../../shared/tests
)

add_test(NAME dedicated_actuator_journal_persistence_tests
         COMMAND dedicated_actuator_journal_persistence_tests)

add_executable(dedicated_actuator_boot_order_tests
    test_dedicated_actuator_boot_order.c
)

target_compile_definitions(dedicated_actuator_boot_order_tests PRIVATE
    VG_DEDICATED_MAIN_SOURCE="${CMAKE_CURRENT_LIST_DIR}/../src/main.c"
)

add_test(NAME dedicated_actuator_boot_order_tests
         COMMAND dedicated_actuator_boot_order_tests)

add_executable(dedicated_actuator_topology_transition_tests
    test_dedicated_actuator_topology_transition.c
    ../src/dedicated_actuator_topology_transition.c
)

target_include_directories(dedicated_actuator_topology_transition_tests PRIVATE
    ../src
    ../../shared
)

add_test(NAME dedicated_actuator_topology_transition_tests
         COMMAND dedicated_actuator_topology_transition_tests)

add_executable(dedicated_actuator_topology_update_order_tests
    test_dedicated_actuator_topology_update_order.c
)

target_compile_definitions(dedicated_actuator_topology_update_order_tests PRIVATE
    VG_DEDICATED_MQTT_SOURCE="${CMAKE_CURRENT_LIST_DIR}/../src/mqtt_node.c"
)

add_test(NAME dedicated_actuator_topology_update_order_tests
         COMMAND dedicated_actuator_topology_update_order_tests)

add_executable(dedicated_actuator_topology_receive_boundary_tests
    test_dedicated_actuator_topology_receive_boundary.c
    ../../shared/actuator_command_guard.c
    ../../shared/actuator_topology.c
    ../../shared/json_lite.c
)

target_include_directories(dedicated_actuator_topology_receive_boundary_tests PRIVATE
    ../src
    ../../shared
)

target_compile_definitions(dedicated_actuator_topology_receive_boundary_tests PRIVATE
    VG_DEDICATED_MQTT_SOURCE="${CMAKE_CURRENT_LIST_DIR}/../src/mqtt_node.c"
)

add_test(NAME dedicated_actuator_topology_receive_boundary_tests
         COMMAND dedicated_actuator_topology_receive_boundary_tests)
