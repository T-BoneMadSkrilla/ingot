# hakuX on macOS (Apple silicon): the prototype that answers whether the core
# can run on a 16 KiB-page host. FEXCore from the fork, hakuX's CPU glue, and
# the 4 KiB-on-16 KiB guest memory layer with its smoke test.
cmake_minimum_required(VERSION 3.20)
project(hakux_mac LANGUAGES C CXX)

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

include("${CMAKE_CURRENT_LIST_DIR}/../native/cmake/fex.cmake")

add_library(hakux_cpu STATIC
  ../native/cpu/cpu.cpp
  ../native/core/log.c
)
target_include_directories(hakux_cpu PUBLIC "${CMAKE_CURRENT_LIST_DIR}/..")
target_link_libraries(hakux_cpu PUBLIC nc_fex)

add_executable(vm16k_smoke proto/smoke.cpp proto/vm16k.c proto/trap.c)
target_link_libraries(vm16k_smoke PRIVATE hakux_cpu)
