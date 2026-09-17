cmake_minimum_required(VERSION 3.16)
project(victory_garden_combined_journal_boot_tests C)
set(CMAKE_C_STANDARD 11)
add_compile_options(-Wall -Wextra -Werror)
enable_testing()
add_executable(combined_actuator_journal_boot_tests
    test_combined_actuator_journal_boot.c
    ../../shared/tests/simulated_flash_backend.c
    ../src/combined_actuator_journal_maintenance.c
    ../src/combined_actuator_journal_runtime_state.c
    ../../shared/actuator_start_journal_storage.c
    ../../shared/actuator_start_journal_flash_codec.c
    ../../shared/actuator_start_journal.c
    ../../shared/actuator_command_freshness.c
)
target_include_directories(combined_actuator_journal_boot_tests PRIVATE ../src ../../shared ../../shared/tests)
add_test(NAME combined_actuator_journal_boot_tests COMMAND combined_actuator_journal_boot_tests)
add_executable(combined_actuator_journal_admission_tests
    test_combined_actuator_journal_admission.c
    ../src/combined_actuator_journal_admission.c
    ../src/combined_actuator_journal_runtime_state.c
    ../../shared/actuator_start_journal.c
    ../../shared/actuator_command_freshness.c
)
target_include_directories(combined_actuator_journal_admission_tests PRIVATE ../src ../../shared)
add_test(NAME combined_actuator_journal_admission_tests COMMAND combined_actuator_journal_admission_tests)
add_executable(combined_actuator_journal_persistence_tests
    test_combined_actuator_journal_persistence.c ../../shared/tests/simulated_flash_backend.c
    ../src/combined_actuator_journal_persistence.c ../src/combined_actuator_journal_admission.c
    ../src/combined_actuator_journal_runtime_state.c ../../shared/actuator_flash_mutation_policy.c
    ../../shared/actuator_start_journal_storage.c ../../shared/actuator_start_journal_flash_codec.c
    ../../shared/actuator_start_journal.c ../../shared/actuator_command_freshness.c)
target_include_directories(combined_actuator_journal_persistence_tests PRIVATE ../src ../../shared ../../shared/tests)
add_test(NAME combined_actuator_journal_persistence_tests COMMAND combined_actuator_journal_persistence_tests)
