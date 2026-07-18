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

> Status: **Phase-3 system feature set** (see the roadmap in
> [`k_printf_hdl_gelistirme_notu.md`](../k_printf_hdl_gelistirme_notu.md)). Working and
> locally verified end-to-end: formatting core (buffer-free, synthesizable),
> UART chain, multi-source triggers + arbiter, capture/tee sinks, and a
> register-window front-end for softcore clients.

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
- **Multi-source triggers** (`kp_trig`): N `{trig, msg_id, args}` sources; arguments
  are captured in a **one-cycle atomic snapshot** (the guarantee software printf can
  never give), then a round-robin, message-granular arbiter feeds the core — bytes of
  different sources never interleave (the structural `k_printf_lock`). A source that
  re-fires while its slot is in flight is counted in its saturating `dropped_cnt`
  (the plan's DROP policy for hardware sources).
- **Capture sink** (`kp_capture`): the `k_snprintf` analogue — stores the stream into
  a RAM (truncating at DEPTH, still counting) and counts completed messages.
- **Tee** (`kp_tee`): broadcast one stream to two sinks (the `k_fprintf` multi-sink
  idea, e.g. UART + capture at once). A registered fork holds each byte until both
  sinks accept it — `a_valid`/`b_valid` depend only on `in_valid` and internal state,
  so there is no combinational `valid`↔`ready` loop (safe with ready-when-valid sinks).
- **Register window** (`kp_regs`): ARG0..7 + **write-to-fire SEND** (the SEND write is
  the trigger — no set-id/go race) + STATUS (pend/err/overflow-count). ARG registers are
  **snapshotted when SEND fires**, so a message that is queued while the core is busy is
  immune to later ARG writes (matching `kp_trig`). Softcore clients use the generated
  `k_printf_hw.h` bridge (written to `hdl/gen/` by `make -C hdl fmtgen`): message ids +
  arity table + an inline poll-then-fire sender — printf with the format strings
  compiled out of the firmware entirely.
- **Bus front-ends** (`kp_axil`, `kp_wb`): thin **AXI4-Lite** and **Wishbone B4**
  slave adapters over `kp_regs`, so a softcore drops the core onto a standard bus. Both
  translate the bus handshake to `kp_regs`' simple `{wen,addr,wdata,rdata}` port
  (word-addressed); `kp_regs` still owns write-to-fire SEND and the arg snapshot.
- **Feature gates** (`G_EN_DEC`, `G_EN_STR` — the `K_PRINTF_ENABLE_*` analogue): with
  a gate at 0 the FSM branch is unreachable and synthesis prunes the datapath
  (measured: 2328 → 1836 LUT4). `k_fmtgen --disable` keeps the ROM consistent; a
  gated-off µop reaching the core is treated as malformed (defense in depth).

Not yet (documented so this doesn't over-claim): runtime ASCII-format front-end
(optional in the plan; formats are compile-time here), formal (sby), nextpnr fmax.
`%f/%e/%g`, `%n`, 64-bit are out of scope (symmetric with the C library).

## Layout

```
hdl/
  fmt/messages.h        single source of truth: the example message set (X-macro)
  fmt/messages_min.h    reduced set for the G_EN_* opt-out config test
  rtl/sv/               kp_core.sv  kp_uart_tx.sv  kp_trig.sv  kp_tee.sv
                        kp_capture.sv  kp_regs.sv  kp_axil.sv  kp_wb.sv
  rtl/vhdl/             VHDL-2008 twins, structural mirror (same names/ports/FSMs)
  tb/kp_tb.sv/.vhd      core differential TB (back-pressure + negative tests)
  tb/kp_uart_tb.sv/.vhd system chain: core -> UART, serial line sampled at real
                        bit times by an independent receiver model
  tb/kp_sys_tb.sv/.vhd  trig -> core -> tee -> 2x capture (atomic snapshot,
                        round-robin vs golden, DROP counting, tee equality)
  tb/kp_regs_tb.sv/.vhd register window: write-to-fire, STATUS contract, overflow
  tb/kp_bus_tb.sv/.vhd  AXI4-Lite + Wishbone -> kp_regs -> core -> capture vs golden
  tb/run_ghdl.sh        GHDL analyze+elaborate+run (with an Apple-Silicon fallback)
  gold/kp_gold.c        golden harness: links the real k_printf, prints oracle bytes
  gen/                  GENERATED (mem images, headers, dispatch, vectors, hw header)
  Makefile              local verification targets
tools/k_fmtgen.py       messages.h -> uop ROM / pools / dispatch / vectors / k_printf_hw.h
docs/hdl/fmt_isa.md     the frozen micro-op ISA (v2)
```

## Build & verify (local; no CI)

Everything is local, symmetric with the C side's `make test`:

```bash
make -C hdl test        # everything: core diff + equiv, UART, sys, regs, config
# or individually:
make -C hdl fmtgen      # regenerate hdl/gen/ from messages.h
make -C hdl gold        # build the C golden, emit expected.txt, check k_printf_hw.h
make -C hdl sim-sv      # Icarus: SV core byte-for-byte vs the C library
make -C hdl sim-vhdl    # GHDL:  VHDL core byte-for-byte vs the C library
make -C hdl equiv       # triple-diff: C = SV = VHDL
make -C hdl sim-uart-sv sim-uart-vhdl   # core -> UART, real-bit-time serial check
make -C hdl sim-sys-sv sim-sys-vhdl     # trig -> core -> tee -> captures
make -C hdl sim-regs-sv sim-regs-vhdl   # register window (write-to-fire)
make -C hdl sim-bus-sv sim-bus-vhdl     # AXI4-Lite + Wishbone front-ends
make -C hdl config-test                 # G_EN_DEC=0,G_EN_STR=0 matrix run
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
  torture formats), SV and VHDL each byte-for-byte equal to the C golden; plus
  fresh-seed `fuzz` re-runs (700+ vectors) — all green.
- ✅ Triple-diff C = SV = VHDL, with randomized back-pressure on **both** TBs (SV LFSR,
  VHDL LFSR, alternating per message) — the byte stream is proven independent of
  `ready` timing.
- ✅ Directed negative tests in both TBs: invalid `msg_id` (silent drop + `err`),
  the ready-pulse-train check (no consecutive `msg_ready` on the drop path — a
  duplicate pulse could swallow a later message), malformed µop (`err` + EOM marker,
  zero data bytes), and post-error recovery.
- ✅ UART chain verified in both languages: core → `kp_uart_tx` → serial line sampled
  at real bit times by an independent receiver model (framing checked).
- ✅ System chain verified in both languages (`kp_sys_tb`): two triggers firing in the
  **same cycle** both come out complete and in round-robin order, byte-for-byte equal
  to the golden; tee sinks identical; `dropped_cnt` counts a re-fire exactly once. The
  trigger inputs are **poisoned right after the pulse**, so the test actually
  discriminates the one-cycle atomic snapshot (a live-read design would emit garbage).
- ✅ Register window verified in both languages (`kp_regs_tb`): write-to-fire output
  equals the golden; STATUS.pend contract; SEND-while-pending counted as overflow
  while the queued message is still delivered; and an **arg-snapshot** test that
  poisons the ARG registers while a message is queued and checks the delivered bytes
  still carry the fire-time args.
- ✅ Bus front-ends verified in both languages (`kp_bus_tb`): driving `kp_regs` over
  **AXI4-Lite** and over **Wishbone** each emits the message byte-for-byte equal to the
  golden, and register read-back (STATUS + an ARG) returns the right values.
- ✅ Config matrix (`config-test`): reduced message set (`--disable dec,oct,bin,str,ptr`)
  against a core elaborated with `G_EN_DEC=0, G_EN_STR=0` — differential green.
- ✅ Synthesis (yosys 0.67, iCE40): `kp_core` full = **2328 SB_LUT4** + 1 BRAM;
  gated (`G_EN_DEC=0,G_EN_STR=0`) = **1836 SB_LUT4** (the gates genuinely prune);
  `kp_uart_tx` = **85 SB_LUT4**. The full-core number is still **above** the plan's
  900–1300 hypothesis band — recorded as the honest calibration result. One safe
  size lever was applied (merging the mutually-exclusive `pw_tmp`/`ddbin` datapath
  registers: 2349 → 2328, differential-verified); the larger levers (digit array →
  shift register, string/lit pools → BRAM, mux sharing) are deferred so as not to
  destabilize the fully-green datapath, not blockers.
- ⚠️ Not covered locally: formal (sby) and nextpnr fmax (tools not installed);
  Verilator/nvc alternates; on-silicon bring-up.

## License

MIT, same as the C library (see [`../LICENSE`](../LICENSE)).
