# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.0] - 2026-07-19

No C library behaviour changes — the bump adds the HDL bus front-ends and a size lever.

### HDL
- **`kp_axil`** (AXI4-Lite) and **`kp_wb`** (Wishbone B4) slave adapters over `kp_regs`,
  both languages: a softcore can now drop the register window onto a standard bus.
  Verified end-to-end (`kp_bus_tb`, SV+VHDL): a message driven over each bus comes out
  byte-for-byte equal to the C golden, and register read-back (STATUS/ARG) is correct.
- **Area lever**: merged the mutually-exclusive `pw_tmp`/`ddbin` datapath registers
  (double-dabble vs pow2/string are never live together): `kp_core` 2349 → **2328
  SB_LUT4** on iCE40, differential-verified. Larger levers stay documented as future
  work.
- **Fix**: `make -C hdl fuzz` now restores `hdl/gen/` to a consistent default state
  (regenerates `expected.txt`, not just `vectors.txt`) so a later manual sim can't read
  a stale golden. `make clean` also clears `hdl/gen_min/`.
- New local targets `sim-bus-sv` / `sim-bus-vhdl`, wired into `make -C hdl test`.

## [2.2.0] - 2026-07-18

No C library behaviour changes — the bump covers the HDL Phase-3 system feature set.

### HDL
- **Buffer-free emit refactor**: the core streams each field phase-by-phase from
  counters instead of materializing it — `kp_core` now synthesizes. Calibration
  (yosys, iCE40): full **2328 SB_LUT4** + 1 BRAM, gated **1836**, UART 85. The
  full-core number exceeds the plan's 900–1300 hypothesis; reduction levers are
  documented as future work.
- **`kp_trig`** (both languages): N-source hardware triggers with a one-cycle atomic
  argument snapshot, round-robin message-granular arbiter, per-source saturating
  `dropped_cnt` (DROP policy for hardware sources).
- **`kp_capture`** (k_snprintf analogue) and **`kp_tee`** (two-sink broadcast,
  the k_fprintf idea) sinks.
- **`kp_regs`**: bus-agnostic register window — ARG0..7, **write-to-fire SEND**
  (no set-id/go race), STATUS (pend/err/overflow). Generated **`k_printf_hw.h`**
  C bridge (ids + arity + inline poll-then-fire sender) — softcore printf with the
  format strings compiled out of firmware.
- **Feature gates** `G_EN_DEC`/`G_EN_STR` (K_PRINTF_ENABLE_* analogue) + `k_fmtgen
  --disable` + a config-matrix differential test with a reduced message set.
- New local targets: `sim-sys-*`, `sim-regs-*`, `config-test`; test totals per run:
  304+304 core, 12+12 UART, 53+53 system, 35+35 regs, 52 config — all vs the C golden.

## [2.1.0] - 2026-07-18

No C library behaviour changes in this release — the version bump covers the new
hardware (HDL) core in the same repo (shared SemVer per the HDL plan).

### HDL
- New `hdl/` hardware `printf` core (`k_printf_hdl`): a synthesizable-RTL,
  vendor-neutral SystemVerilog + VHDL-2008 implementation that reuses the C formatting
  rules to emit a formatted ASCII byte stream over a `valid`/`ready` handshake. Not a
  translation — a separate core driven from a micro-op ROM compiled by
  `tools/k_fmtgen.py`, with **this C library as its golden model** (oracle chain
  `snprintf → k_printf → k_printf_hdl`).
- Feature set (µop ISA v2, `docs/hdl/fmt_isa.md`): specifiers
  `%d %i %u %x %X %o %b %B %p %c %s %%` + literals, flags `- 0 # + space`, field
  width and `.precision` 0..63 (literal or `*` from an argument, C semantics incl.
  negative `*`), `l` (32-bit), `h/hh` ignored; decimal via serial double-dabble
  (no divider); C's exact layout rules (`0`+precision, `%.0d`-of-0, `%#o`,
  C11 `%#.0o`-of-0, INT_MIN-safe magnitude).
- Defined error behaviour: invalid `msg_id` / malformed µop → drop + sticky `err`,
  never hangs; µop ROM carries a magic+version header the cores verify at run time.
- `kp_uart_tx` (both languages): 8N1 UART sink with a fractional (N.F) baud
  accumulator; system chain core→UART verified against the golden at real bit times.
  First synthesis calibration: 85 SB_LUT4 on iCE40 (yosys).
- Local verification (`make -C hdl test`, no CI): 300 differential vectors + directed
  negative tests, SV (Icarus) and VHDL (GHDL) each byte-for-byte equal to the C
  golden under randomized back-pressure; triple-diff C = SV = VHDL; fresh-seed
  `make -C hdl fuzz` re-runs (700+ vectors).
- Known limitation (honest): the reference core's field buffer makes `kp_core` itself
  impractical to synthesize until the planned buffer-free emit refactor; the UART and
  all simulation semantics are unaffected. Roadmap: `k_printf_hdl_gelistirme_notu.md`.

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
