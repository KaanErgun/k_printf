# k_printf_hdl — hardware `printf` core

A synthesizable, vendor-neutral hardware equivalent of the [k_printf](../README.md)
C library: it takes a compile-time format and run-time binary arguments and emits the
formatted **ASCII byte stream** over a `valid`/`ready` handshake (typical sink: a UART
TX). Both a **SystemVerilog** and a **VHDL-2008** implementation are provided.

This is **not** a line-by-line translation of the C code. It is a separate core that
reuses the *same formatting rules*: the C library `k_printf` is the golden model, and
both HDL cores are checked byte-for-byte against it. Formatting is deferred the way
`defmt`/`Trice` do it — formats are compiled to a micro-op ROM at build time, and only
the arguments travel at run time.

> Status: **Phase-2 feature set** (see the roadmap in
> [`k_printf_hdl_gelistirme_notu.md`](../k_printf_hdl_gelistirme_notu.md)). Working and
> locally verified end-to-end, including the UART system chain.

## What it does

- Consumes messages `{msg_id, args}` and streams the formatted bytes out.
- Specifiers: `%d %i %u %x %X %o %b %B %p %c %s`, plus `%%` and literal text.
- Flags `-` `0` `#` `+` space, field **width** and **`.precision`** 0..63 (literal or
  **`*`** from an argument, C semantics incl. negative `*`), the `l` (32-bit)
  modifier; `h/hh` accepted and ignored (C mirror).
- Decimal via **serial double-dabble** — no divider (the RTL echo of MSP430's
  "no hardware divide").
- INT_MIN-safe magnitude (`0 - value` in unsigned space), the C library's exact
  three-branch field layout, `0`-flag-ignored-with-precision, `%.0d`-of-0 emits
  nothing, and the `%#o` / C11 `%#.0o`-of-0 rules.
- Registered `valid`/`ready` output with back-pressure (the core stalls when the sink
  isn't ready — the hardware image of the C library's blocking `putc`).
- **Defined error behaviour:** an invalid `msg_id` or a malformed/reserved µop drops
  the message, raises the sticky `err` flag and returns to idle — never hangs. The
  µop ROM carries a magic+version header; a mismatched ROM is refused with `err`.
- **UART sink** (`kp_uart_tx`, both languages): 8N1, fractional (N.F) baud
  accumulator — no derived clock, the RTL echo of MSP430's `UCBRS` modulation.

Not yet (Phase-3 hooks, documented so this doesn't over-claim): runtime ASCII-format
front-end, multi-source triggers + arbiter, capture/snprintf sink, register-map/AXI
front-ends. `%f/%e/%g`, `%n`, 64-bit are out of scope (symmetric with the C library).

## Layout

```
hdl/
  fmt/messages.h        single source of truth: the example message set (X-macro)
  rtl/sv/kp_core.sv     SystemVerilog core
  rtl/sv/kp_uart_tx.sv  SystemVerilog UART TX (8N1, fractional baud)
  rtl/vhdl/kp_core.vhd  VHDL-2008 twin (structural mirror: same entity/ports/FSM)
  rtl/vhdl/kp_uart_tx.vhd  VHDL-2008 UART TX twin
  tb/kp_tb.sv           Icarus testbench (differential vs C golden, back-pressure,
                        directed negative tests)
  tb/kp_tb.vhd          GHDL testbench (ditto, incl. back-pressure + negatives)
  tb/kp_uart_tb.sv/.vhd system chain: core -> UART, serial line sampled at real
                        bit times by an independent receiver model
  tb/run_ghdl.sh        GHDL analyze+elaborate+run (with an Apple-Silicon fallback)
  gold/kp_gold.c        golden harness: links the real k_printf, prints oracle bytes
  gen/                  GENERATED (mem images, headers, dispatch, vectors) — see below
  Makefile              local verification targets
tools/k_fmtgen.py       messages.h -> uop ROM / pools / dispatch / vectors
docs/hdl/fmt_isa.md     the frozen micro-op ISA (v2)
```

## Build & verify (local; no CI)

Everything is local, symmetric with the C side's `make test`:

```bash
make -C hdl test        # fmtgen -> gold -> SV + VHDL diff -> triple-diff -> UART chain
# or individually:
make -C hdl fmtgen      # regenerate hdl/gen/ from messages.h
make -C hdl gold        # build the C golden and emit expected.txt
make -C hdl sim-sv      # Icarus: SV core byte-for-byte vs the C library
make -C hdl sim-vhdl    # GHDL:  VHDL core byte-for-byte vs the C library
make -C hdl equiv       # triple-diff: C = SV = VHDL
make -C hdl sim-uart-sv sim-uart-vhdl   # core -> UART, real-bit-time serial check
make -C hdl fuzz FUZZ_SEED=123 FUZZ_N=48  # same differential, fresh random vectors
```

The oracle chain is `snprintf → C k_printf → k_printf_hdl`: the golden model is the
same C code that the C test suite already validates against the platform `snprintf`,
so testing the hardware also exercises the region the C fuzzer had to exclude for lack
of an `snprintf` oracle (`%b/%B`, `%p`, the `(null)` string, `%%`).

### Toolchain

| Tool | Role | Verified with |
|------|------|---------------|
| Python 3 | `k_fmtgen.py` (stdlib only) | 3.x |
| C compiler | golden model (`kp_gold` links `src/k_printf.c`) | Apple clang |
| Icarus Verilog | SV core simulation | `iverilog` 13.0 |
| GHDL `--std=08` | VHDL core simulation | GHDL 5.1.1 |

On Apple Silicon a Rosetta (x86_64) GHDL can't link against the native arm64
toolchain; `tb/run_ghdl.sh` detects the failed native elaborate and falls back to a
manual `arch -x86_64 clang -arch x86_64` link. On Linux / native macOS the standard
`ghdl -a/-e/-r` path is used. Verilator, yosys/nextpnr (area/fmax), and sby (formal)
are optional and simply skipped when absent.

## Adding or changing messages

Edit [`fmt/messages.h`](fmt/messages.h) (`K_MSG(SYMBOL, "format")`), then
`make -C hdl test`. `k_fmtgen.py` re-derives the µop ROM, the per-message C dispatch
(so the golden prints the same format text the hardware was built from), and fresh
test vectors. A format outside the supported subset (e.g. `%f` or `ll`) fails
generation with a clear error — the grammar authority stays in the C library.

## The micro-op ISA

Frozen in [`fmt_isa.md`](../docs/hdl/fmt_isa.md) (**v2**: precision/`*` fields + ROM
header word). Both cores decode exactly those field positions. The µop ROM's word 0
is a `"KP"`-magic + version header; the cores check it at run time and refuse a
mismatched ROM with the sticky `err` flag — no silent "old ROM, new RTL" runs.

## Verification status (honest)

- ✅ 300 differential vectors (directed + seeded-random, covering precision/`*`
  torture formats), SV and VHDL each byte-for-byte equal to the C golden; plus a
  fresh-seed `fuzz` re-runs (700+ vectors) — all green.
- ✅ Triple-diff C = SV = VHDL, with randomized back-pressure on **both** TBs (SV LFSR,
  VHDL LFSR, alternating per message) — the byte stream is proven independent of
  `ready` timing.
- ✅ Directed negative tests in both TBs: invalid `msg_id` (silent drop + `err`),
  the ready-pulse-train check (no consecutive `msg_ready` on the drop path — a duplicate pulse could swallow a later message), malformed µop (`err` + EOM marker, zero data bytes), and post-error recovery.
- ✅ System chain verified in both languages: core → `kp_uart_tx` → serial line sampled
  at real bit times by an independent receiver model (12 messages, framing checked).
- ✅ First synthesis calibration: `kp_uart_tx` = **85 SB_LUT4** on iCE40 (yosys 0.67).
- ⚠️ `kp_core` itself is **not yet practically synthesizable**: the reference
  implementation assembles each field into a 96-byte buffer, whose guarded-write loops
  explode into a mux network that yosys chews on for >10 min. This is exactly the
  plan's Phase-2 "buffer-free emit" refactor (stream the field phase-by-phase with
  counters instead of materializing it); until then the area budget for the core stays
  a hypothesis. Simulation semantics are unaffected.

## License

MIT, same as the C library (see [`../LICENSE`](../LICENSE)).
