# hakuX on macOS (Apple silicon): the prototype that answers whether the core
# can run on a 16 KiB-page host. FEXCore from the fork, hakuX's CPU glue, and
# the 4 KiB-on-16 KiB guest memory layer with its smoke test.
cmake_minimum_required(VERSION 3.20)
project(hakux_mac LANGUAGES C CXX OBJC)

if(NOT APPLE OR NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
  message(FATAL_ERROR "mac/ builds on Apple silicon only")
endif()
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Linux headers FEX includes that Darwin lacks (shims), for FEX and the core alike.
include_directories(BEFORE SYSTEM "${CMAKE_CURRENT_LIST_DIR}/compat/include")

# The whole native core (FEX, kernel, HLE GPU on MoltenVK, APU) and xboxrun.
get_filename_component(NC_DEPS_DEFAULT "${CMAKE_CURRENT_LIST_DIR}/../../deps" ABSOLUTE)
set(NC_DEPS "${NC_DEPS_DEFAULT}" CACHE PATH "native core third-party sources")
add_subdirectory(../native native)

find_path(NC_VULKAN_INCLUDE vulkan/vulkan.h HINTS /opt/homebrew/include /usr/local/include REQUIRED)
target_include_directories(nc_volk SYSTEM PUBLIC "${NC_VULKAN_INCLUDE}")
foreach(t hakux_native hakux_hle hakux_apu nc_slirp nc_glib xboxrun)
  target_compile_options(${t} PRIVATE
    "$<$<COMPILE_LANGUAGE:C>:SHELL:-include ${CMAKE_CURRENT_LIST_DIR}/compat/darwin_compat.h>")
endforeach()

# The window xboxrun presents to (mac/window.m), through the app's presenter.
target_sources(xboxrun PRIVATE window.m ../native/app/present.c)
set_source_files_properties(window.m PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(xboxrun PRIVATE "-framework Cocoa" "-framework QuartzCore" "-framework GameController")

add_library(hakux_cpu STATIC
  ../native/cpu/cpu.cpp
  ../native/core/log.c
)
target_include_directories(hakux_cpu PUBLIC "${CMAKE_CURRENT_LIST_DIR}/..")
target_link_libraries(hakux_cpu PUBLIC nc_fex)

add_executable(vm16k_smoke proto/smoke.cpp proto/vm16k.c proto/trap.c)
target_link_libraries(vm16k_smoke PRIVATE hakux_cpu)

# The 16 KiB-page access emulator against the CPU (mac/test/vm16k_diff.c).
add_executable(vm16k_diff test/vm16k_diff.c)
target_link_libraries(vm16k_diff PRIVATE hakux_hle hakux_native)
target_compile_options(vm16k_diff PRIVATE
  "SHELL:-include ${CMAKE_CURRENT_LIST_DIR}/compat/darwin_compat.h")
