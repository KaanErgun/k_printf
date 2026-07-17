# k_printf v2.0 - build the static library, the MSP430 example, and host tests.
#
# Cross build (default target = MSP430):
#   make lib          # -> libk_printf.a
#   make example      # -> example.elf + example_ringbuf.elf
#   make MCU=msp430fr5969 lib
#   make CROSS=msp430-elf- lib      # TI's msp430-gcc toolchain naming
# Host tests (native compiler + sanitizers):
#   make test
# Differential fuzzing against the host snprintf:
#   make fuzz               # clang libFuzzer (FUZZ_TIME seconds)
#   make fuzz-standalone    # deterministic self-driving run (any compiler)
# Install the lib + header:
#   make install PREFIX=/usr/local

# ---- Cross toolchain (target: MSP430) ----
CROSS   ?= msp430-
CC      := $(CROSS)gcc
AR      := $(CROSS)ar
MCU     ?= msp430g2553

CPPFLAGS ?= -Iinclude
CFLAGS   ?= -mmcu=$(MCU) -Os -std=c11 -Wall -Wextra \
            -ffunction-sections -fdata-sections
LDFLAGS  ?= -Wl,--gc-sections

# ---- Host toolchain (for tests) ----
HOSTCC   ?= cc
HOSTFLAGS ?= -std=c11 -Wall -Wextra -Werror -Iinclude \
             -fsanitize=address,undefined -g

PREFIX  ?= /usr/local
BUILD   := build
FUZZ_TIME ?= 60

.PHONY: all lib example test fuzz fuzz-standalone clean install uninstall

all: lib example

# ---- Static library ----
lib: libk_printf.a

libk_printf.a: $(BUILD)/k_printf.o
	$(AR) rcs $@ $^

$(BUILD)/k_printf.o: src/k_printf.c include/k_printf.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

# ---- MSP430 example firmware ----
example: example.elf example_ringbuf.elf

example.elf: examples/main.c libk_printf.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $< -L. -lk_printf

example_ringbuf.elf: examples/uart_ringbuf.c libk_printf.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $< -L. -lk_printf

# ---- Host test suite ----
test: $(BUILD)
	$(HOSTCC) $(HOSTFLAGS) src/k_printf.c tests/test_k_printf.c -o $(BUILD)/test
	./$(BUILD)/test
	$(HOSTCC) $(HOSTFLAGS) -DK_PRINTF_ENABLE_LONG=0 -DK_PRINTF_ENABLE_HEX=0 \
	      -DK_PRINTF_ENABLE_OCTAL=0 -DK_PRINTF_ENABLE_BIN=0 \
	      -DK_PRINTF_ENABLE_PTR=0 \
	      src/k_printf.c tests/test_optout.c -o $(BUILD)/test_optout
	./$(BUILD)/test_optout

# ---- Differential fuzzing (vs host snprintf) ----
# `fuzz` needs a clang with libFuzzer (Linux clang, or llvm from Homebrew).
# `fuzz-standalone` runs the same target self-driven with a fixed seed and
# works with any compiler (Apple clang ships without libFuzzer).
fuzz: | $(BUILD)
	clang -std=c11 -g -fsanitize=fuzzer,address,undefined -Iinclude \
	      src/k_printf.c tests/fuzz_k_printf.c -o $(BUILD)/fuzz
	./$(BUILD)/fuzz -max_total_time=$(FUZZ_TIME)

fuzz-standalone: | $(BUILD)
	$(HOSTCC) -std=c11 -g -fsanitize=address,undefined -DFUZZ_STANDALONE \
	      -Iinclude src/k_printf.c tests/fuzz_k_printf.c \
	      -o $(BUILD)/fuzz_standalone
	./$(BUILD)/fuzz_standalone

$(BUILD):
	mkdir -p $(BUILD)

# ---- Install / uninstall ----
install: lib
	install -d $(DESTDIR)$(PREFIX)/include $(DESTDIR)$(PREFIX)/lib
	install -m644 include/k_printf.h $(DESTDIR)$(PREFIX)/include/
	install -m644 libk_printf.a       $(DESTDIR)$(PREFIX)/lib/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/include/k_printf.h
	rm -f $(DESTDIR)$(PREFIX)/lib/libk_printf.a

clean:
	rm -rf $(BUILD) libk_printf.a *.elf *.o *.map
