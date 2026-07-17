# k_printf_hdl µop ISA — v1 (frozen)

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

Flags and width sit at the **same bit positions** in FMT, STR and CHR so the RTL
decodes them once:

| bits | field | meaning |
|------|-------|---------|
| `[9:5]` | `flags` | bit0 `ZERO` (`0`), bit1 `LEFT` (`-`), bit2 `PLUS` (`+`), bit3 `SPACE` (` `), bit4 `HASH` (`#`) |
| `[15:10]` | `width` | minimum field width, 0..63 (`G_MAX_FIELD = 63`, documented deviation from C's INT_MAX) |

### FMT payload (adds, on top of shared fields)

| bits | field | meaning |
|------|-------|---------|
| `[1:0]` | `base` | `00`=decimal(10), `01`=hex(16), `10`=octal(8), `11`=binary(2) |
| `[2]` | `upper` | uppercase digits (`%X`,`%B`) |
| `[3]` | `is_signed` | signed decimal (`%d`,`%i`) — magnitude via `0 - value` (INT_MIN-safe, C-mirror) |
| `[4]` | `size32` | `0` = use low 16 bits of the arg slot (sign-extended if `is_signed`); `1` = full 32 bits (`l`) |
| `[18:16]` | `arg_slot` | which argument word (0..7) feeds this conversion |

For `is_signed=0` the flags `PLUS`/`SPACE` are ignored (C: sign flags apply only to
signed conversions). `HASH` gives `0x`/`0X` (hex), `0b`/`0B` (binary), a leading `0`
(octal); suppressed when the value is zero (except octal, which keeps a single `0`).

### STR payload

| bits | field | meaning |
|------|-------|---------|
| `[18:16]` | `arg_slot` | argument word (0..7) holding the string-table id |

`%s` in this ROM front-end takes its argument as a **string-table id** (the plan's
runtime-parser `%s`-as-table-id model), not a memory pointer: the argument word selects
a compile-time entry `str_table[id] = {addr,len}` in the string pool. So `%s` **does**
consume one argument word (the id), the length is known at compile time (right-justified
width is free), and there is no NUL-terminated-string lockup class. `ZERO` is ignored for
`%s` (C rule); `LEFT`/`width` apply. `str_id = 0` is `"(null)"` in the RTL string pool,
and the C golden passes a NULL `char*` for id 0 — so both sides exercise the library's
own `(null)` output.

### CHR payload

| bits | field | meaning |
|------|-------|---------|
| `[18:16]` | `arg_slot` | argument word whose low 8 bits are emitted |

`ZERO` is ignored for `%c`; `LEFT`/`width` apply (space padding).

## Message layout & tables

Messages are laid out sequentially in the µop ROM, each terminated by an `EOM`.
`k_fmtgen.py` also emits:

- `msg_start[msg_id]` → first µop word index of each message.
- `msg_arity[msg_id]` → number of argument words the message consumes. **This table is
  the sole authority on arity** — the message record carries no `argc` field, so a
  client cannot desync it (the RTL image of C's "unknown specifier consumes no arg"
  guarantee: arg consumption is fixed by the compiled µops, never by runtime data).
- String pool + `str_table[str_id] = {addr,len}`.

## ROM header / versioning

`k_fmtgen.py` stamps `KP_ISA_VERSION` (currently **1**) into the generated constant
headers. The RTL compares its compiled-in `KP_ISA_VERSION` against the ROM's and, on
mismatch, refuses to run (drives an error status) — this removes the "old ROM image +
new RTL" silent-failure class.

## Error behaviour (frozen, so `no-deadlock` can be proved)

- **Invalid `msg_id`** (≥ message count): the message is dropped, a sticky error status
  bit + `err_cnt` is set, and the engine returns to idle. It never hangs.
- **Malformed µop** (reserved `op`): same — drop the message, flag error, return to idle.
- These paths are exercised by directed negative tests (`BAD_MSG`, `BAD_UOP`).

## Deferred in the current reference slice (Phase-2 hooks)

`.precision`, `*` (arg-sourced width/precision) are **not yet** encoded. Formats using
them are rejected by `k_fmtgen.py` with a clear error. When added, `precision[5:0]` +
`prec_en` and `w_from_arg`/`p_from_arg` land in the FMT payload reserved bits, `base`
stays at `[1:0]`. The frozen positions above do not move.
