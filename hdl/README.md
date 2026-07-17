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

> Status: **Phase-1 reference slice** (see the roadmap in
> [`../k_printf_hdl_gelistirme_notu.md`](../k_printf_hdl_gelistirme_notu.md), one level
> up). It is a working, locally-verified vertical slice, not the full Phase-3 product.

## What it does

- Consumes messages `{msg_id, args}` and streams the formatted bytes out.
- Specifiers: `%d %i %u %x %X %o %b %B %p %c %s`, plus `%%` and literal text.
- Flags `-` `0` `#` `+` space, field **width** 0..63, and the `l` (32-bit) modifier.
- Decimal via **serial double-dabble** — no divider (the RTL echo of MSP430's
  "no hardware divide").
- INT_MIN-safe magnitude (`0 - value` in unsigned space), the C library's exact
  three-branch field layout, the `0`-flag-ignored-with-precision and `%#o` rules.
- Registered `valid`/`ready` output with back-pressure (the core stalls when the sink
  isn't ready — the hardware image of the C library's blocking `putc`).

Not yet (Phase-2/3 hooks, documented so the slice doesn't over-claim): `.precision`,
`*` (arg-sourced width), a runtime ASCII-format front-end, multi-source triggers +
arbiter, capture/snprintf sink, register-map/AXI front-ends. `%f/%e/%g`, `%n`, 64-bit
are out of scope (symmetric with the C library's limitations).

## Layout

```
hdl/
  fmt/messages.h        single source of truth: the example message set (X-macro)
  rtl/sv/kp_core.sv     SystemVerilog core
  rtl/vhdl/kp_core.vhd  VHDL-2008 twin (structural mirror: same entity/ports/FSM)
  tb/kp_tb.sv           Icarus testbench (differential vs C golden, back-pressure)
  tb/kp_tb.vhd          GHDL  testbench (differential vs C golden)
  tb/run_ghdl.sh        GHDL analyze+elaborate+run (with an Apple-Silicon fallback)
  gold/kp_gold.c        golden harness: links the real k_printf, prints oracle bytes
  gen/                  GENERATED (mem images, headers, dispatch, vectors) — see below
  Makefile              local verification targets
tools/k_fmtgen.py       messages.h -> uop ROM / pools / dispatch / vectors
docs/hdl/fmt_isa.md     the frozen micro-op ISA (v1)
```

## Build & verify (local; no CI)

Everything is local, symmetric with the C side's `make test`:

```bash
make -C hdl test        # fmtgen -> gold -> SV diff -> VHDL diff -> triple-diff
# or individually:
make -C hdl fmtgen      # regenerate hdl/gen/ from messages.h
make -C hdl gold        # build the C golden and emit expected.txt
make -C hdl sim-sv      # Icarus: SV core byte-for-byte vs the C library
make -C hdl sim-vhdl    # GHDL:  VHDL core byte-for-byte vs the C library
make -C hdl equiv       # triple-diff: C = SV = VHDL
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
test vectors. A format outside the supported subset (e.g. using `.precision`) fails
generation with a clear error — the grammar authority stays in the C library.

## The micro-op ISA

Frozen in [`../docs/hdl/fmt_isa.md`](../docs/hdl/fmt_isa.md). Both cores decode exactly
those field positions; `k_fmtgen.py` stamps `KP_ISA_VERSION` into the generated headers
so an old ROM image against a newer core is a detectable mismatch rather than a silent
one.

## Verification status (honest)

- ✅ 165 differential vectors (directed + seeded-random), SV and VHDL each byte-for-byte
  equal to the C golden, under ASan-clean generation.
- ✅ Triple-diff C = SV = VHDL, with the SV run under randomized back-pressure and the
  VHDL run always-ready — so the byte stream is proven independent of `ready` timing.
- ⚠️ The invalid-`msg_id` / malformed-µop **error paths exist in both cores** (drop the
  message, raise `err`, never hang) but are not yet driven by a directed negative test
  in the TBs — a Phase-2 item.
- ⚠️ No synthesis/area/fmax numbers yet (yosys/nextpnr not run here); the budget tables
  in the plan are still hypotheses to be calibrated in Phase-1 hardware bring-up.

## License

MIT, same as the C library (see [`../LICENSE`](../LICENSE)).
