# k_printf

🔧 Lightweight, freestanding `printf` for MSP430 and other small microcontrollers.
🎯 No `malloc`, no libc `printf`, no format buffer required — output goes one byte
at a time through a callback you supply.

![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-MSP430-blue)
![Language](https://img.shields.io/badge/language-C-lightgrey)
![Version](https://img.shields.io/badge/version-2.1.0-orange)

> This is the canonical README. A Turkish summary lives in
> [docs/README.tr.md](docs/README.tr.md) (may lag behind this file).

---

## ✨ Features

- Specifiers: `d i u x X o b B c s p %` plus the `%%` literal
- **`long` support** via the `l` modifier (`%ld %lu %lx %lX %lo %lb`) — essential
  on MSP430, where `int` is only 16-bit
- Field **width**, **precision**, and flags `-` `+` `space` `0` `#`, plus `*`
  (width/precision from an argument)
- Returns the number of characters written (like standard `printf`)
- `k_snprintf` / `k_vsnprintf` for formatting into a buffer
- Multiple output sinks via an explicit sink handle + `userdata`
- Reentrant core (`k_vprintf_cb`) with no global state
- Overridable `k_printf_lock()`/`k_printf_unlock()` hooks (weak no-ops by
  default) to make whole messages atomic on the global-sink path
- Per-specifier compile switches to trim code size
- No dynamic memory; C11; `extern "C"` for C++
- Tested against the host `snprintf` (unit suite + differential fuzzer) under
  ASan/UBSan; builds for MSP430 with `msp430-gcc`

---

## 🚀 Quick start

```c
#include <msp430.h>
#include "k_printf.h"

/* v2.0 callback signature: (char, void *userdata) */
static void uart_putc(char c, void *userdata) {
    (void)userdata;
    while (!(IFG2 & UCA0TXIFG)) { }
    UCA0TXBUF = (unsigned char)c;
}

int main(void) {
    WDTCTL = WDTPW | WDTHOLD;
    k_printf_init(uart_putc, NULL);

    k_printf("Value: %d (hex %#x)\n", 42, 42);      // Value: 42 (hex 0x2a)
    k_printf("Tick: %lu\n", 1000000UL);             // needs %l — 32-bit
    k_printf("Port: %08b\n", 0xA5);                 // Port: 10100101
}
```

---

## 🧪 Supported format specifiers

Grammar: `%[flags][width][.precision][l]specifier`

| Specifier | Argument type | Meaning | Example |
|-----------|---------------|---------|---------|
| `%d`, `%i` | `int` | Signed decimal (INT_MIN-safe) | `-123` |
| `%u` | `unsigned int` | Unsigned decimal | `123` |
| `%x` / `%X` | `unsigned int` | Hex, lower/upper, **no prefix** | `2a` / `2A` |
| `%o` | `unsigned int` | Octal | `52` |
| `%b` / `%B` | `unsigned int` | Binary (MSB first) | `101010` |
| `%c` | `int` | Single character | `A` |
| `%s` | `const char *` | String (`NULL` → `(null)`) | `hi` |
| `%p` | `void *` | Pointer, `0x`-prefixed hex | `0x1a2b` |
| `%%` | — | A literal `%` | `%` |
| `%ld %lu %lx %lX %lo %lb` | `long` / `unsigned long` | **32-bit** variants | `4000000000` |

**Flags:** `-` left-justify · `+` always show sign · `space` blank before positives ·
`0` zero-pad · `#` alternate form (`0x`/`0X` for hex, `0b`/`0B` for binary, leading `0` for octal).

**Width / precision:** `%8d`, `%-8s`, `%08x`, `%.3d`, `%10.5s`, and `*` for a
run-time value: `%*d`, `%-*.*d`.

> **Note:** plain `%x` no longer prints a `0x` prefix (v1 did). Use `%#x` for the
> prefix. See [Migration](#-migrating-from-1x).

---

## ⚠️ Limitations

- **16-bit ranges** without `l`: `%d` is −32768..32767, `%u` is 0..65535, `%x` is
  up to 4 nibbles. Use `%ld`/`%lu`/`%lx` for 32-bit values on MSP430.
- No floating point (`%f`, `%e`, `%g`), no `%n`.
- An **unknown specifier is echoed literally** (e.g. `%q` → `%q`) and does **not**
  consume an argument.
- A lone trailing `%` at the end of the format string is dropped.
- The `h`/`hh` length modifiers are parsed but ignored (on MSP430 `int` *is*
  16-bit, so they change nothing there; on 32-bit hosts pass values in range).
- `%p` prints `0` for a NULL pointer (and `0x…` otherwise).
- The `putc` callback must not return before the byte is accepted (block, or
  enqueue into a TX ring buffer).
- The core is reentrant, but character-by-character output to a shared device is
  **not atomic** by default: calling `k_printf` from both an ISR and the main
  context can interleave bytes. Use an interrupt-driven TX ring buffer plus the
  `k_printf_lock()`/`k_printf_unlock()` overrides — see
  [examples/uart_ringbuf.c](examples/uart_ringbuf.c) — or serialize access
  yourself.

---

## 🛠️ Building

```bash
make lib                       # -> libk_printf.a (MSP430, msp430-gcc)
make example                   # -> example.elf + example_ringbuf.elf
make MCU=msp430fr5969 lib      # different device
make CROSS=msp430-elf- lib     # TI's toolchain naming (msp430-elf-gcc)
make test                      # host build + run the test suite (ASan/UBSan)
make fuzz FUZZ_TIME=60         # differential fuzz vs snprintf (clang libFuzzer)
make fuzz-standalone           # same fuzzer, deterministic, any compiler
make install PREFIX=/usr/local # install lib + header
```

With CMake:

```bash
# Host tests
cmake -S . -B build -DK_PRINTF_BUILD_TESTS=ON && cmake --build build && ctest --test-dir build

# MSP430 cross-build
cmake -S . -B bcross -DCMAKE_TOOLCHAIN_FILE=cmake/msp430-toolchain.cmake \
      -DK_PRINTF_BUILD_EXAMPLES=ON -DMSP430_MCU=msp430g2553
cmake --build bcross
```

### Trimming code size

Every optional specifier group can be disabled at compile time; a disabled one is
echoed literally and consumes no argument:

```bash
gcc -Iinclude -DK_PRINTF_ENABLE_BIN=0 -DK_PRINTF_ENABLE_PTR=0 -c src/k_printf.c
```

Switches: `K_PRINTF_ENABLE_LONG`, `_HEX`, `_OCTAL`, `_BIN`, `_PTR` (all default `1`).
The `d i u c s %%` core is always built.

---

## 🔌 Beyond the global sink

```c
/* Format into a buffer */
char line[32];
int n = k_snprintf(line, sizeof line, "%s=%ld", "count", 100000L);

/* Independent sinks (e.g. UART and an in-RAM log) */
k_printf_sink_t uart = { uart_putc, NULL };
k_printf_sink_t ring = { ring_putc, &my_ringbuf };
k_fprintf(&uart, "hello %d\n", 1);
k_fprintf(&ring, "hello %d\n", 1);

/* Build your own printf-like wrapper on the reentrant core */
int log_printf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = k_vprintf_cb(uart_putc, NULL, fmt, ap);
    va_end(ap);
    return r;
}

/* Make whole k_printf() messages atomic: override the weak no-op hooks.
 * They wrap the global-sink path only (not k_fprintf/k_snprintf). */
void k_printf_lock(void)   { /* e.g. save interrupt state + disable */ }
void k_printf_unlock(void) { /* restore */ }
```

For non-blocking output that also stops ISR/main byte interleaving, see the
interrupt-driven TX ring buffer example:
[examples/uart_ringbuf.c](examples/uart_ringbuf.c) (`make example` builds it as
`example_ringbuf.elf`).

---

## 🔀 Migrating from 1.x

v2.0 is a breaking release. Two behaviour changes and one API change:

| Change | 1.x | 2.0 | Action |
|--------|-----|-----|--------|
| `putc` callback | `void f(char)` | `void f(char, void *userdata)` | Add the `userdata` param |
| `k_printf_init` | `init(f)` | `init(f, userdata)` | Pass `NULL` if unused |
| `%x` prefix | printed `0x` | no prefix | Use `%#x` where you relied on `0x` |
| `%%` | printed `%%` | prints `%` | Remove workarounds that used a single `%` |
| Return type | `void` | `int` (chars written) | Optional: check the count |

Everything else (`%d %u %c %s`, plain literals) is source-compatible.

---

## 🧪 Testing

`make test` builds a host harness ([tests/test_k_printf.c](tests/test_k_printf.c))
that formats each case with both `k_printf` and the platform `snprintf` and
asserts equality, under `-fsanitize=address,undefined`. It covers every v1 bug
(INT_MIN, trailing `%`, `%%`, NULL `%s`, unknown specifier), the new
width/precision/flag/long paths, the lock hooks, and a set of 16-bit boundary
vectors (`INT16_MIN`, `UINT16_MAX`, …).

`make fuzz` runs a **differential fuzzer**
([tests/fuzz_k_printf.c](tests/fuzz_k_printf.c)) that decodes fuzz input into
defined-behaviour format strings and compares `k_snprintf` byte-for-byte
against the host `snprintf` (libFuzzer + ASan/UBSan). `make fuzz-standalone`
drives the same target deterministically with any compiler.

> **16 vs 32-bit caveat:** the host `int` is 32-bit, so the harness exercises the
> INT_MIN negation path with the *host* `INT_MIN`, not MSP430's −32768; the
> 16-bit vectors pin the expected output but not the 16-bit arithmetic. Validate
> true 16-bit behaviour on an MSP430 simulator (mspdebug `simu` / QEMU) capturing
> UART bytes.

API reference docs can be generated with Doxygen: `cd docs && doxygen Doxyfile`
(output in `docs/doxygen/html/`).

---

## 🔩 Hardware (HDL) core

A synthesizable hardware equivalent lives in [hdl/](hdl/): a vendor-neutral
SystemVerilog + VHDL-2008 core (`k_printf_hdl`) that reuses these same formatting
rules to emit a formatted ASCII byte stream over a `valid`/`ready` handshake (e.g. to a
UART TX) — for CPU-less FPGA designs. It is **not** a translation of the C code: formats
are compiled to a micro-op ROM by [tools/k_fmtgen.py](tools/k_fmtgen.py), and **this C
library is its golden model** — both HDL cores are checked byte-for-byte against
`k_snprintf` (oracle chain `snprintf → k_printf → k_printf_hdl`).

```bash
make -C hdl test     # k_fmtgen -> C golden -> SV + VHDL differential -> triple-diff -> UART chain
```

Current status (Phase 2): specifiers `%d %i %u %x %X %o %b %B %p %c %s %%`, flags
`- 0 # + space`, width and `.precision` incl. `*`, `l`; decimal via double-dabble;
defined error paths + ROM version header; an 8N1 UART sink (`kp_uart_tx`, fractional
baud) with the full chain verified at real bit times. 300 differential vectors +
negative tests + fresh-seed fuzz, C = SV = VHDL under randomized back-pressure. See
[hdl/README.md](hdl/README.md) and the roadmap in `k_printf_hdl_gelistirme_notu.md`.

---

## 📜 License

MIT © [KaanErgun](https://github.com/KaanErgun) — see [LICENSE](LICENSE).

See [CHANGELOG.md](CHANGELOG.md) for release history.
