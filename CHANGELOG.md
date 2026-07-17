# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### HDL
- New `hdl/` hardware `printf` core (`k_printf_hdl`): a synthesizable, vendor-neutral
  SystemVerilog + VHDL-2008 implementation that reuses the C formatting rules to emit a
  formatted ASCII byte stream over a `valid`/`ready` handshake. Not a translation — a
  separate core driven from a micro-op ROM compiled by `tools/k_fmtgen.py`, with **this
  C library as its golden model**.
- Phase-1 reference slice: specifiers `%d %i %u %x %X %o %b %B %p %c %s %%`, flags
  `- 0 # + space`, field width, and `l`; decimal via serial double-dabble (no divider).
- Local verification (`make -C hdl test`, no CI): 165 differential vectors, SV (Icarus,
  randomized back-pressure) and VHDL (GHDL) each byte-for-byte equal to the C golden;
  triple-diff C = SV = VHDL.
- Frozen micro-op ISA (`docs/hdl/fmt_isa.md`) and the plan
  (`k_printf_hdl_gelistirme_notu.md`, repo root).

## [2.0.0] - 2026-07-17

A correctness- and feature-focused rewrite. This release is **breaking**: the
`putc` callback signature and two output behaviours changed. See "Migrating from
1.x" in the README.

### Fixed
- **INT_MIN / most-negative values** no longer trigger signed-overflow UB or
  print garbage (`%d` of −32768 on MSP430 previously printed `-(`). Magnitude is
  now computed in unsigned space.
- **Lone trailing `%`** at the end of a format string no longer reads past the
  NUL terminator (out-of-bounds read); it is now dropped safely.
- **`%%`** now prints a single `%` (previously printed `%%`).
- **`%s` with a NULL pointer** now prints `(null)` instead of dereferencing NULL.
- Calling `k_printf` before init (NULL sink) now returns `K_PRINTF_ERR` instead
  of calling through a NULL function pointer.
- Unknown specifiers no longer risk desyncing the vararg stream — they are echoed
  literally and consume no argument. The same contract now genuinely holds for
  a disabled `K_PRINTF_ENABLE_LONG`: `%ld` is echoed, not silently read as `int`.
- `%#.0o` with the value 0 prints `0` as C11 requires (was empty).
- Width/precision parsing, `%*d` with an `INT_MIN` width argument, and the
  padding arithmetic no longer overflow `int` (saturating; matters doubly on
  16-bit-`int` MSP430, where `%32768d` already overflowed).

### Added
- **`long` support**: `%ld %lu %lx %lX %lo %lb` (essential on 16-bit-`int` MSP430).
- **Field width, precision, and flags** `-` `+` `space` `0` `#`, plus `*` for
  width/precision from an argument.
- New specifiers: `%X` (uppercase hex), `%o` (octal), `%b`/`%B` (binary), `%p`
  (pointer), `%i` (alias of `%d`).
- **Return value**: all formatting functions now return the character count
  (or `K_PRINTF_ERR`).
- **Buffer output**: `k_snprintf` / `k_vsnprintf` (ISO truncation semantics).
- **Explicit sinks**: `k_printf_sink_t`, `k_fprintf`, `k_vfprintf`, and a
  reentrant core `k_vprintf_cb`, plus `k_vprintf`.
- `userdata` pointer threaded through the `putc` callback.
- Overridable `k_printf_lock()`/`k_printf_unlock()` critical-section hooks
  (weak no-ops by default) around the global-sink path.
- Interrupt-driven TX ring buffer example (`examples/uart_ringbuf.c`):
  non-blocking output, no ISR/main byte interleaving.
- Per-specifier compile switches: `K_PRINTF_ENABLE_LONG/_HEX/_OCTAL/_BIN/_PTR`.
- `extern "C"` guard and `K_PRINTF_VERSION*` macros in the header.
- Host test suite (`tests/`) incl. 16-bit boundary vectors, CMake build +
  MSP430 toolchain file.
- Differential fuzzer vs the host `snprintf` (`tests/fuzz_k_printf.c`,
  libFuzzer + deterministic standalone mode).
- Doxygen config (`docs/Doxyfile`) and Doxygen-style API comments.

### Changed
- **Breaking:** `putc` callback is now `void f(char c, void *userdata)` and
  `k_printf_init(putc, userdata)` takes the userdata pointer.
- **Breaking:** plain `%x`/`%X` no longer print a `0x`/`0X` prefix — use `%#x`.
- Project layout flattened (removed the nested duplicate `k_printf/` directory);
  single `LICENSE` (full MIT text), single canonical README.
- Digit conversion uses one division per digit (remainder derived from the
  quotient) — one software-divide call instead of two on MSP430 — and the digit
  buffer is sized from the type instead of a hard-coded constant.

## [1.0.0]

- Initial release: `%d %u %x %c %s`, single global `putc` callback, MSP430 focus.
