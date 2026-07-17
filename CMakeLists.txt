cmake_minimum_required(VERSION 3.13)
project(k_printf VERSION 2.0.0 LANGUAGES C)

# Static library
add_library(k_printf STATIC src/k_printf.c)
target_include_directories(k_printf PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)
target_compile_features(k_printf PUBLIC c_std_11)

# Optional feature switches (default ON). Turn off to shrink code size, e.g.
#   cmake -DK_PRINTF_ENABLE_BIN=OFF ..
foreach(feat LONG HEX OCTAL BIN PTR)
    option(K_PRINTF_ENABLE_${feat} "Enable %${feat} conversions" ON)
    if(NOT K_PRINTF_ENABLE_${feat})
        target_compile_definitions(k_printf PRIVATE K_PRINTF_ENABLE_${feat}=0)
    endif()
endforeach()

# Host tests (only when building natively, not cross-compiling)
option(K_PRINTF_BUILD_TESTS "Build host test suite" OFF)
if(K_PRINTF_BUILD_TESTS AND NOT CMAKE_CROSSCOMPILING)
    enable_testing()
    add_executable(k_printf_test tests/test_k_printf.c src/k_printf.c)
    target_include_directories(k_printf_test PRIVATE include)
    add_test(NAME k_printf_test COMMAND k_printf_test)
endif()

# MSP430 examples (only when cross-compiling for it)
option(K_PRINTF_BUILD_EXAMPLES "Build the MSP430 examples" OFF)
if(K_PRINTF_BUILD_EXAMPLES AND CMAKE_CROSSCOMPILING)
    add_executable(example examples/main.c)
    target_link_libraries(example PRIVATE k_printf)
    set_target_properties(example PROPERTIES OUTPUT_NAME example.elf)

    add_executable(example_ringbuf examples/uart_ringbuf.c)
    target_link_libraries(example_ringbuf PRIVATE k_printf)
    set_target_properties(example_ringbuf PROPERTIES OUTPUT_NAME example_ringbuf.elf)
endif()

# Install rules
include(GNUInstallDirs)
install(TARGETS k_printf ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(FILES include/k_printf.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
