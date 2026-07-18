# k_printf_hdl µop ISA — v2 (frozen)

The hardware core (`kp_core`) consumes a stream of 32-bit micro-ops (µops) fetched
from a ROM produced by `tools/k_fmtgen.py` out of `hdl/fmt/messages.h`. This file is
the **single frozen definition** of the encoding; `k_fmtgen.py`, the SystemVerilog
core, and the VHDL core all implement exactly these field positions. A change here is
a **minor version bump** (`KP_ISA_VERSION`) and must land atomically in all four
places (codegen + two RTLs + this doc).

Design mirror of the C library: the µop engine is the RTL image of `k_vprintf_cb`
(the stateless core); the ROM front-end is the image of the `k_printf`/`k_snprintf`
wrappers. Formatting is done at synthesis time (format → µop ROM); only the binary
arguments are supplied at run time — the hardware analogue of `defmt`/`Trice`
"deferred formatting".

## Word layout

```
 31    29 28                                                     0
+--------+------------------------------------------------------+
|  op[3] |                     payload[29]                       |
+--------+------------------------------------------------------+
```

`op = word[31:29]` (3 bits, 8 slots, 3 reserved for growth):

| op | name | meaning |
|----|------|---------|
| `000` | **LIT** | stream literal bytes from the literal pool |
| `001` | **FMT** | format one integer argument (all bases) |
| `010` | **STR** | emit a ROM string-table entry (`%s`, compile-time id) |
| `011` | **CHR** | emit one character from an argument (`%c`) |
| `111` | **EOM** | end of message → assert `out_last`, report `msg_len` |
| `100`,`101`,`110` | reserved | decoding one of these is a **malformed-µop error** (see below) |

### LIT payload

| bits | field | meaning |
|------|-------|---------|
| `[15:0]` | `lit_addr` | byte address into the literal pool |
| `[27:16]` | `len` | number of bytes to stream (1..4095) |

Plain format text and `%%` are compiled into LIT runs.

### Shared numeric fields (FMT / STR / CHR)

Flags, width, precision and the `*` markers sit at the **same bit positions** in FMT,
STR and CHR so the RTL decodes them once:

| bits | field | meaning |
|------|-------|---------|
| `[9:5]` | `flags` | bit0 `ZERO` (`0`), bit1 `LEFT` (`-`), bit2 `PLUS` (`+`), bit3 `SPACE` (` `), bit4 `HASH` (`#`) |
| `[15:10]` | `width` | minimum field width, 0..63 (`G_MAX_FIELD = 63`, documented deviation from C's INT_MAX) |
| `[18:16]` | `arg_slot` | **first** argument slot of this conversion (see argument order below) |
| `[24:19]` | `prec` | literal precision 0..63 (valid when `prec_en`) |
| `[25]` | `prec_en` | a **literal** precision was given (`.N`); for `.*` this bit is 0 and the effective enable is resolved at run time from the argument's sign |
| `[26]` | `w_from_arg` | width comes from an argument (`*`) |
| `[27]` | `p_from_arg` | precision comes from an argument (`.*`) |
| `[28]` | reserved | must be 0 |

**Argument order per conversion** (mirrors the C `va_arg` order): the conversion's
argument words are laid out sequentially starting at `arg_slot` as
`[width-arg if w_from_arg][prec-arg if p_from_arg][value]`. The RTL derives the value
slot as `arg_slot + w_from_arg + p_from_arg`, so consumption is still fixed entirely
by the compiled µop — a client can never desync it.

**`*` semantics (C mirror, with the field cap):** the width/precision arguments are
read as **signed 32-bit** regardless of the `size` bit. A negative `*` width acts as
the `-` flag with the absolute value; a negative `.*` precision means "no precision".
Magnitudes are saturated to `G_MAX_FIELD = 63`; values beyond that are a **documented
deviation** from C (the golden-model test generator constrains `*` arguments to the
supported range).

**Precision semantics (C mirror):** precision is the minimum digit count (zero-filled)
for numeric conversions and the maximum length for `%s`. `prec==0` with value 0 emits
no digits. The `0` flag is ignored when a precision is present. `%#o` forces a leading
zero only when one isn't already first — including the C11 `%#.0o`-of-0 → `"0"` case.
Precision on `%c` is undefined in C and rejected by `k_fmtgen`.

### FMT payload (adds, on top of shared fields)

| bits | field | meaning |
|------|-------|---------|
| `[1:0]` | `base` | `00`=decimal(10), `01`=hex(16), `10`=octal(8), `11`=binary(2) |
| `[2]` | `upper` | uppercase digits (`%X`,`%B`) |
| `[3]` | `is_signed` | signed decimal (`%d`,`%i`) — magnitude via `0 - value` (INT_MIN-safe, C-mirror) |
| `[4]` | `size32` | `0` = use low 16 bits of the value slot (sign-extended if `is_signed`); `1` = full 32 bits (`l`) |

`PLUS`/`SPACE` apply to **all** conversions, unsigned included — the golden C library
(`src/k_printf.c` `fmt_int`) prints the sign character for any non-negative value
regardless of signedness, which is its own documented deviation from ISO C, and the
cores mirror the golden exactly (pinned by the `MSG_SIGNU` differential message).
`HASH` gives `0x`/`0X` (hex), `0b`/`0B` (binary), a leading `0` (octal, via the
precision path — see above); the hex/binary prefix is suppressed when the value is
zero. The `h`/`hh` length modifiers are accepted by `k_fmtgen` and ignored (the C
library does the same; the no-`l` datapath is 16-bit anyway).

### STR payload

Uses only the shared fields. `%s` in this ROM front-end takes its argument as a
**string-table id** (the plan's runtime-parser `%s`-as-table-id model), not a memory
pointer: the argument word selects a compile-time entry `str_table[id] = {addr,len}`
in the string pool. So `%s` **does** consume one argument word (the id, at the derived
value slot), the length is known at compile time (right-justified width is free), and
there is no NUL-terminated-string lockup class. The id is computed as
`arg[15:0] mod N_STRINGS` (low 16 bits — keeps the VHDL integer range and the golden
dispatch exactly aligned). `ZERO` is ignored for `%s` (C rule);
`LEFT`/`width`/`precision` apply (precision truncates). `str_id = 0` is `"(null)"` in
the RTL string pool, and the C golden passes a NULL `char*` for id 0 — so both sides
exercise the library's own `(null)` output.

### CHR payload

Uses only the shared fields (the value slot's low 8 bits are emitted). `ZERO` is
ignored for `%c`; `LEFT`/`width` (including `*` width) apply with space padding;
precision is rejected at generation time.

## Message layout & tables

**Word 0 of the µop ROM is a header**: `0x4B50_0000 | KP_ISA_VERSION` (`"KP"` magic in
the top 16 bits, version in the low 8). Messages start at word 1; `msg_start` entries
already include the offset. On the first message accept, the core compares the header
against its compiled-in expectation and, on mismatch, raises the sticky `err` flag and
drops every message — the "old ROM image + new RTL" class fails loudly instead of
printing garbage.

Messages are laid out sequentially after the header, each terminated by an `EOM`.
The **last message id is a deliberately malformed test message** (a reserved opcode
followed by `EOM`), exported as `KP_BAD_UOP_MSG_ID`; it is excluded from the golden
vectors and exists so the testbenches can drive the malformed-µop error path.
`k_fmtgen.py` also emits:

- `msg_start[msg_id]` → first µop word index of each message.
- `msg_arity[msg_id]` → number of argument words the message consumes. **This table is
  the sole authority on arity** — the message record carries no `argc` field, so a
  client cannot desync it (the RTL image of C's "unknown specifier consumes no arg"
  guarantee: arg consumption is fixed by the compiled µops, never by runtime data).
- String pool + `str_table[str_id] = {addr,len}`.

## Versioning

`KP_ISA_VERSION` is currently **2** (v2 added the precision/`*` fields in previously
reserved FMT/STR/CHR payload bits and the ROM header word). `k_fmtgen.py` stamps the
version into the ROM header (word 0) and the generated constant headers; the RTL
checks the header at run time as described above.

## Error behaviour (frozen, so `no-deadlock` can be proved)

- **Invalid `msg_id`** (≥ message count) or a **mismatched ROM header**: the message is
  refused with **zero output handshakes** (a one-cycle drop bounce guarantees exactly
  one `msg_ready` pulse per presented message), the sticky `err` flag is set, and the
  engine returns to idle. It never hangs.
- **Malformed µop** (reserved `op`, **or a conversion for a feature disabled by a
  `G_EN_*` gate** — e.g. a decimal FMT with `G_EN_DEC=0`, a STR with `G_EN_STR=0`): the
  message body is abandoned, `err` is set, and the engine emits the **`out_last`
  end-of-message marker** (zero data bytes) before returning to idle — observably
  different from the invalid-`msg_id` case, so a consumer that counts message frames
  stays aligned. (`k_fmtgen --disable` keeps a gated build's ROM from containing such a
  µop in the first place; the run-time check is defense in depth.)
- These paths are exercised by directed negative tests (`BAD_MSG`, ready-pulse-train,
  `BAD_UOP`, post-error recovery).

## Front-/back-ends outside this ISA

The multi-source triggers/arbiter (`kp_trig`), capture (`snprintf`) sink (`kp_capture`),
tee (`kp_tee`), the register-window front-end (`kp_regs`) and its **AXI4-Lite / Wishbone
adapters** (`kp_axil` / `kp_wb`) sit in front of or behind the µop engine and **do not
change the encoding** — they are implemented (both languages) as of v2.3.0. A runtime
ASCII-format parser front-end remains optional/future and likewise would not touch the
ISA. `ll`/64-bit
and floating point are out of scope entirely (symmetric with the C library).
