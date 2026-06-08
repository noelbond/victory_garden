if(CMAKE_C_COMPILER)
  return()
endif()

set(_arm_gnu_toolchain_bin "")

if(DEFINED ENV{ARM_GNU_TOOLCHAIN_BIN} AND EXISTS "$ENV{ARM_GNU_TOOLCHAIN_BIN}/arm-none-eabi-gcc")
  set(_arm_gnu_toolchain_bin "$ENV{ARM_GNU_TOOLCHAIN_BIN}")
else()
  find_program(_arm_none_eabi_gcc arm-none-eabi-gcc)

  if(_arm_none_eabi_gcc)
    execute_process(
      COMMAND "${_arm_none_eabi_gcc}" -print-file-name=nosys.specs
      OUTPUT_VARIABLE _nosys_specs
      OUTPUT_STRIP_TRAILING_WHITESPACE
      ERROR_QUIET
    )

    if(IS_ABSOLUTE "${_nosys_specs}" AND EXISTS "${_nosys_specs}")
      get_filename_component(_arm_gnu_toolchain_bin "${_arm_none_eabi_gcc}" DIRECTORY)
    endif()
  endif()

  if(NOT _arm_gnu_toolchain_bin AND APPLE)
    file(GLOB _arm_gnu_candidates "/Applications/ArmGNUToolchain/*/arm-none-eabi/bin/arm-none-eabi-gcc")
    if(_arm_gnu_candidates)
      list(SORT _arm_gnu_candidates COMPARE NATURAL ORDER DESCENDING)
      list(GET _arm_gnu_candidates 0 _preferred_arm_gnu_gcc)
      get_filename_component(_arm_gnu_toolchain_bin "${_preferred_arm_gnu_gcc}" DIRECTORY)
    endif()
  endif()
endif()

if(_arm_gnu_toolchain_bin)
  set(CMAKE_C_COMPILER "${_arm_gnu_toolchain_bin}/arm-none-eabi-gcc" CACHE FILEPATH "ARM GNU C compiler" FORCE)
  set(CMAKE_CXX_COMPILER "${_arm_gnu_toolchain_bin}/arm-none-eabi-g++" CACHE FILEPATH "ARM GNU C++ compiler" FORCE)
  set(CMAKE_ASM_COMPILER "${_arm_gnu_toolchain_bin}/arm-none-eabi-gcc" CACHE FILEPATH "ARM GNU ASM compiler" FORCE)
  message(STATUS "Using ARM GNU toolchain from ${_arm_gnu_toolchain_bin}")
endif()
