# Reserves the final 28 KiB only for actuator-capable images. The SDK default
# memmap is copied into the build directory with its generated FLASH region
# include replaced; all board-specific RAM and section rules remain SDK-owned.
set(VG_ACTUATOR_PERSISTENT_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(vg_reserve_actuator_persistent_flash TARGET)
  set(VG_ACTUATOR_PERSISTENT_SECTOR_SIZE 4096)
  set(VG_ACTUATOR_PERSISTENT_PROTECTED_TAIL_SIZE "7 * ${VG_ACTUATOR_PERSISTENT_SECTOR_SIZE}")
  math(EXPR VG_ACTUATOR_PERSISTENT_FLASH_SIZE_BYTES "${PICO_FLASH_SIZE_BYTES}")
  math(EXPR VG_ACTUATOR_PERSISTENT_TAIL_BYTES "${VG_ACTUATOR_PERSISTENT_PROTECTED_TAIL_SIZE}")
  if(VG_ACTUATOR_PERSISTENT_FLASH_SIZE_BYTES LESS VG_ACTUATOR_PERSISTENT_TAIL_BYTES)
    message(FATAL_ERROR "${TARGET}: flash is too small for the 28 KiB persistent tail")
  endif()
  if(NOT EXISTS "${PICO_LINKER_SCRIPT_PATH}/memmap_default.ld")
    message(FATAL_ERROR "${TARGET}: Pico SDK default linker script is unavailable")
  endif()

  set(VG_ACTUATOR_PERSISTENT_FLASH_REGION
      "${CMAKE_CURRENT_BINARY_DIR}/${TARGET}_persistent_flash_region.ld")
  file(WRITE "${VG_ACTUATOR_PERSISTENT_FLASH_REGION}"
       "FLASH(rx) : ORIGIN = 0x10000000, LENGTH = (${PICO_FLASH_SIZE_BYTES} - ${VG_ACTUATOR_PERSISTENT_PROTECTED_TAIL_SIZE})\n")

  file(READ "${PICO_LINKER_SCRIPT_PATH}/memmap_default.ld" VG_ACTUATOR_PERSISTENT_MEMMAP)
  string(FIND "${VG_ACTUATOR_PERSISTENT_MEMMAP}" "INCLUDE \"pico_flash_region.ld\""
         VG_ACTUATOR_PERSISTENT_INCLUDE_OFFSET)
  if(VG_ACTUATOR_PERSISTENT_INCLUDE_OFFSET EQUAL -1)
    message(FATAL_ERROR "${TARGET}: SDK memmap no longer includes pico_flash_region.ld")
  endif()
  string(REPLACE "INCLUDE \"pico_flash_region.ld\""
                 "INCLUDE \"${VG_ACTUATOR_PERSISTENT_FLASH_REGION}\""
                 VG_ACTUATOR_PERSISTENT_MEMMAP "${VG_ACTUATOR_PERSISTENT_MEMMAP}")
  set(VG_ACTUATOR_PERSISTENT_MEMMAP_FILE
      "${CMAKE_CURRENT_BINARY_DIR}/${TARGET}_persistent_memmap.ld")
  file(WRITE "${VG_ACTUATOR_PERSISTENT_MEMMAP_FILE}" "${VG_ACTUATOR_PERSISTENT_MEMMAP}")
  pico_set_linker_script(${TARGET} "${VG_ACTUATOR_PERSISTENT_MEMMAP_FILE}")

  add_custom_command(TARGET ${TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND}
      "-DVG_NM=${CMAKE_NM}"
      "-DVG_ELF=$<TARGET_FILE:${TARGET}>"
      "-DVG_FLASH_SIZE_BYTES=${VG_ACTUATOR_PERSISTENT_FLASH_SIZE_BYTES}"
      "-DVG_PROTECTED_TAIL_BYTES=${VG_ACTUATOR_PERSISTENT_TAIL_BYTES}"
      "-DVG_LABEL=${TARGET}"
      -P "${VG_ACTUATOR_PERSISTENT_CMAKE_DIR}/check_actuator_persistent_flash_tail.cmake"
    VERBATIM
  )
endfunction()
