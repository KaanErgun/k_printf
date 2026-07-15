# k_printf v2.0 - build the static library, the MSP430 example, and host tests.
#
# Cross build (default target = MSP430):
#   make lib          # -> libk_printf.a
#   make example      # -> example.elf
#   make MCU=msp430fr5969 lib
# Host tests (native compiler + sanitizers):
#   make test
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

.PHONY: all lib example test clean install uninstall

all: lib example

# ---- Static library ----
lib: libk_printf.a

libk_printf.a: $(BUILD)/k_printf.o
	$(AR) rcs $@ $^

$(BUILD)/k_printf.o: src/k_printf.c include/k_printf.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

# ---- MSP430 example firmware ----
example: example.elf

example.elf: examples/main.c libk_printf.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $< -L. -lk_printf

# ---- Host test suite ----
test: $(BUILD)
	$(HOSTCC) $(HOSTFLAGS) src/k_printf.c tests/test_k_printf.c -o $(BUILD)/test
	./$(BUILD)/test

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
	rm -rf $(BUILD) libk_printf.a example.elf *.o *.map
