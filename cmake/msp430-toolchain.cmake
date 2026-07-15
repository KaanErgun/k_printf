# MSP430 cross-compilation toolchain file.
#   cmake -DCMAKE_TOOLCHAIN_FILE=cmake/msp430-toolchain.cmake \
#         -DK_PRINTF_BUILD_EXAMPLES=ON -DMSP430_MCU=msp430g2553 ..
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR msp430)

set(MSP430_MCU "msp430g2553" CACHE STRING "Target MSP430 device")

find_program(MSP430_GCC msp430-gcc)
find_program(MSP430_AR  msp430-ar)

set(CMAKE_C_COMPILER "${MSP430_GCC}")
set(CMAKE_AR         "${MSP430_AR}")

set(CMAKE_C_FLAGS_INIT "-mmcu=${MSP430_MCU} -Os -ffunction-sections -fdata-sections")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-Wl,--gc-sections")

# Don't try to run target binaries on the host.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
