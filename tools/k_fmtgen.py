#!/usr/bin/env python3
"""
k_fmtgen.py - compile hdl/fmt/messages.h into the artifacts the k_printf_hdl
hardware core and its C golden model consume.

For each K_MSG(SYMBOL, "format") it parses the format (the frozen grammar in
docs/hdl/fmt_isa.md, ISA v2) and emits, into an output directory:

  uop_rom.mem     32-bit micro-op words; word 0 = header 0x4B50_00vv (vv = ISA ver)
  lit_pool.mem    literal bytes         (one hex byte per line)
  str_pool.mem    string-table bytes    (one hex byte per line)
  str_table.mem   {addr,len} per string id (packed 32-bit: addr[15:0], len[23:16])
  msg_start.mem   first uop word index per message id (already offset past header)
  msg_arity.mem   argument-word count per message id
  kp_msgs.svh     SystemVerilog constants (KP_ISA_VERSION, counts, KP_BAD_UOP_MSG_ID)
  kp_msgs_pkg.vhd VHDL-2008 package with the same constants
  kp_gold.inc     C: per-message dispatch calling the real k_snprintf (the oracle)
  vectors.txt     directed + seeded-random {msg_id nargs a0..} stimuli (hex args)
  messages_report.md   human-readable inventory

The last message id is a deliberately malformed test message (reserved opcode +
EOM), exported as KP_BAD_UOP_MSG_ID: excluded from vectors, driven by the TBs to
exercise the malformed-uop error path.

Supported grammar: %[flags][width][.prec][l]spec with specs d i u x X o b B p c s,
flags - 0 # + space, width/precision 0..63 literal or '*' (arg-sourced), l = 32-bit,
h/hh accepted and ignored. Precision on %c is rejected (C-undefined). '*' argument
values outside -63..63 (width) are a documented deviation from C; the vector
generator constrains them.

Pure standard library, no third-party deps. Deterministic for a given --seed.
"""
import argparse
import os
import re
import sys

KP_ISA_VERSION = 2
ROM_MAGIC = 0x4B500000            # "KP" << 16
G_MAX_FIELD = 63

# ---- micro-op encoding (must match docs/hdl/fmt_isa.md and both RTL cores) ----
OP_LIT, OP_FMT, OP_STR, OP_CHR, OP_EOM = 0, 1, 2, 3, 7
OP_BAD = 4                        # reserved opcode used by the BAD_UOP test message

FLAG_ZERO, FLAG_LEFT, FLAG_PLUS, FLAG_SPACE, FLAG_HASH = 1, 2, 4, 8, 16
BASE_DEC, BASE_HEX, BASE_OCT, BASE_BIN = 0, 1, 2, 3

BAD_UOP_SYMBOL = "KP_TEST_BAD_UOP"

# Compile-time string table shared by RTL (str_pool) and golden (kp_gold).
# id 0 is "(null)": the RTL stores the literal bytes, the golden passes a NULL
# char* so the C library's own "(null)" path is exercised on the oracle side.
STRING_TABLE = ["(null)", "cpu", "mem", "io", "sensor"]


class FmtError(Exception):
    pass


# ---- a parsed conversion -------------------------------------------------
class Conv:
    __slots__ = ("kind", "base", "upper", "signed", "size32", "flags",
                 "width", "prec", "w_star", "p_star", "spec", "text")

    def __init__(self, kind):
        self.kind = kind          # 'LIT' | 'FMT' | 'STR' | 'CHR'
        self.base = BASE_DEC
        self.upper = 0
        self.signed = 0
        self.size32 = 0
        self.flags = 0
        self.width = 0
        self.prec = None          # None = no precision; else 0..63
        self.w_star = False
        self.p_star = False
        self.spec = ""            # original specifier char (for arg typing)
        self.text = b""           # for LIT


def parse_format(fmt):
    """Format string -> list[Conv]. Raises FmtError on anything outside the
    frozen subset (so a bad format fails generation, not silently at run time)."""
    out = []
    lit = bytearray()
    i, n = 0, len(fmt)

    def flush_lit():
        nonlocal lit
        if lit:
            c = Conv("LIT")
            c.text = bytes(lit)
            out.append(c)
            lit = bytearray()

    while i < n:
        ch = fmt[i]
        if ch != "%":
            lit.append(ord(ch))
            i += 1
            continue
        i += 1
        if i >= n:
            raise FmtError("lone trailing '%' is not allowed in a compiled message")
        if fmt[i] == "%":
            lit.append(ord("%"))
            i += 1
            continue
        flush_lit()
        c = Conv("FMT")
        # flags
        while i < n and fmt[i] in "-+ 0#":
            c.flags |= {"-": FLAG_LEFT, "+": FLAG_PLUS, " ": FLAG_SPACE,
                        "0": FLAG_ZERO, "#": FLAG_HASH}[fmt[i]]
            i += 1
        # width: '*' or decimal
        if i < n and fmt[i] == "*":
            c.w_star = True
            i += 1
        else:
            wstart = i
            while i < n and fmt[i].isdigit():
                i += 1
            if i > wstart:
                w = int(fmt[wstart:i])
                if w > G_MAX_FIELD:
                    raise FmtError("width %d exceeds G_MAX_FIELD=%d" % (w, G_MAX_FIELD))
                c.width = w
        # precision: '.' then '*' | digits | nothing (C: bare '.' means 0)
        if i < n and fmt[i] == ".":
            i += 1
            if i < n and fmt[i] == "*":
                c.p_star = True
                i += 1
            else:
                pstart = i
                while i < n and fmt[i].isdigit():
                    i += 1
                p = int(fmt[pstart:i]) if i > pstart else 0
                if p > G_MAX_FIELD:
                    raise FmtError("precision %d exceeds G_MAX_FIELD=%d" % (p, G_MAX_FIELD))
                c.prec = p
        # length modifiers: l = 32-bit; h/hh accepted and ignored (C mirror)
        if i < n and fmt[i] == "l":
            c.size32 = 1
            i += 1
            if i < n and fmt[i] == "l":
                raise FmtError("'ll'/64-bit is out of scope")
        elif i < n and fmt[i] == "h":
            i += 1
            if i < n and fmt[i] == "h":
                i += 1
        if i >= n:
            raise FmtError("format ends inside a conversion")
        spec = fmt[i]
        i += 1
        c.spec = spec
        if spec in ("d", "i"):
            c.base, c.signed = BASE_DEC, 1
        elif spec == "u":
            c.base = BASE_DEC
        elif spec == "x":
            c.base = BASE_HEX
        elif spec == "X":
            c.base, c.upper = BASE_HEX, 1
        elif spec == "o":
            c.base = BASE_OCT
        elif spec == "b":
            c.base = BASE_BIN
        elif spec == "B":
            c.base, c.upper = BASE_BIN, 1
        elif spec == "p":
            # %p = alternate-form lowercase hex, pointer width; k_printf semantics
            c.base, c.flags = BASE_HEX, c.flags | FLAG_HASH
            c.size32 = 1
        elif spec == "c":
            if c.prec is not None or c.p_star:
                raise FmtError("precision on %c is undefined in C and rejected")
            c.kind = "CHR"
        elif spec == "s":
            c.kind = "STR"
        else:
            raise FmtError("unsupported specifier %%%s" % spec)
        out.append(c)
    flush_lit()
    return out


def conv_argtypes(conv):
    """Ordered C arg types this conversion consumes: [*width][*prec][value].
    'int*w'/'int*p' are ints with constrained generator ranges."""
    if conv.kind == "LIT":
        return []
    args = []
    if conv.w_star:
        args.append("int*w")
    if conv.p_star:
        args.append("int*p")
    if conv.kind == "CHR":
        args.append("int")
    elif conv.kind == "STR":
        args.append("str")
    elif conv.spec == "p":
        args.append("ptr")
    elif conv.size32:
        args.append("long" if conv.signed else "unsigned long")
    else:
        args.append("int" if conv.signed else "unsigned")
    return args


# ---- encoders ------------------------------------------------------------
def _shared_bits(conv, arg_slot):
    prec_en = 1 if (conv.prec is not None) else 0
    prec = conv.prec if conv.prec is not None else 0
    return (((1 if conv.p_star else 0) << 27) | ((1 if conv.w_star else 0) << 26) |
            (prec_en << 25) | ((prec & 63) << 19) | ((arg_slot & 7) << 16) |
            ((conv.width & 63) << 10) | ((conv.flags & 31) << 5))


def enc_lit(addr, length):
    assert length < 4096 and addr < 65536
    return (OP_LIT << 29) | ((length & 0xFFF) << 16) | (addr & 0xFFFF)


def enc_fmt(conv, arg_slot):
    return ((OP_FMT << 29) | _shared_bits(conv, arg_slot) |
            ((conv.size32 & 1) << 4) | ((conv.signed & 1) << 3) |
            ((conv.upper & 1) << 2) | (conv.base & 3))


def enc_str(conv, arg_slot):
    return (OP_STR << 29) | _shared_bits(conv, arg_slot)


def enc_chr(conv, arg_slot):
    return (OP_CHR << 29) | _shared_bits(conv, arg_slot)


def enc_eom():
    return OP_EOM << 29


# ---- top-level generation ------------------------------------------------
def read_messages(path):
    txt = open(path, encoding="utf-8").read()
    txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)   # ignore commented K_MSGs
    msgs = []
    for m in re.finditer(r'K_MSG\s*\(\s*([A-Za-z_]\w*)\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)', txt):
        sym, raw = m.group(1), m.group(2)
        msgs.append((sym, decode_c_string(raw)))
    if not msgs:
        raise FmtError("no K_MSG entries found in %s" % path)
    return msgs


def decode_c_string(raw):
    out, i, n = [], 0, len(raw)
    simple = {"n": "\n", "r": "\r", "t": "\t", "0": "\0",
              "\\": "\\", '"': '"', "'": "'"}
    while i < n:
        c = raw[i]
        if c == "\\" and i + 1 < n:
            nxt = raw[i + 1]
            if nxt in simple:
                out.append(simple[nxt]); i += 2; continue
            if nxt == "x":
                j = i + 2
                while j < n and raw[j] in "0123456789abcdefABCDEF":
                    j += 1
                out.append(chr(int(raw[i + 2:j], 16))); i = j; continue
            out.append(nxt); i += 2; continue
        out.append(c); i += 1
    return "".join(out)


def generate(messages, outdir, seed=0xC0FFEE, n_random=8):
    os.makedirs(outdir, exist_ok=True)

    lit_pool = bytearray()
    lit_addr = {}

    def intern_lit(b):
        if b in lit_addr:
            return lit_addr[b]
        a = len(lit_pool)
        lit_addr[b] = a
        lit_pool.extend(b)
        return a

    str_pool = bytearray()
    str_table = []
    for s in STRING_TABLE:
        a = len(str_pool)
        str_pool.extend(s.encode("latin-1"))
        str_table.append((a, len(s)))

    uop = [ROM_MAGIC | KP_ISA_VERSION]     # word 0: header
    msg_start = []
    msg_arity = []
    msg_meta = []                          # (sym, fmt, [argtypes]); fmt None = bad-uop

    for sym, fmt in messages:
        try:
            convs = parse_format(fmt)
        except FmtError as e:
            raise FmtError("%s: %s  (format %r)" % (sym, e, fmt))
        msg_start.append(len(uop))
        slot = 0
        argtypes = []
        for c in convs:
            if c.kind == "LIT":
                a = intern_lit(c.text)
                off, remain = 0, len(c.text)
                while remain:
                    chunk = min(remain, 4095)
                    uop.append(enc_lit(a + off, chunk))
                    off += chunk; remain -= chunk
                continue
            ats = conv_argtypes(c)
            first_slot = slot
            if slot + len(ats) > 8:
                raise FmtError("%s: more than 8 argument words" % sym)
            if c.kind == "FMT":
                uop.append(enc_fmt(c, first_slot))
            elif c.kind == "CHR":
                uop.append(enc_chr(c, first_slot))
            elif c.kind == "STR":
                uop.append(enc_str(c, first_slot))
            argtypes.extend(ats)
            slot += len(ats)
        uop.append(enc_eom())
        msg_arity.append(slot)
        msg_meta.append((sym, fmt, argtypes))

    # deliberately malformed test message (reserved opcode), last id
    msg_start.append(len(uop))
    uop.append(OP_BAD << 29)
    uop.append(enc_eom())
    msg_arity.append(0)
    msg_meta.append((BAD_UOP_SYMBOL, None, []))
    bad_uop_id = len(msg_meta) - 1

    def wmem(name, words, width_nibbles):
        with open(os.path.join(outdir, name), "w") as f:
            for w in words:
                f.write(("%0" + str(width_nibbles) + "x\n") % w)

    wmem("uop_rom.mem", uop, 8)
    wmem("lit_pool.mem", list(lit_pool), 2)
    wmem("str_pool.mem", list(str_pool), 2)
    wmem("str_table.mem", [((l & 0xFF) << 16) | (a & 0xFFFF) for (a, l) in str_table], 8)
    wmem("msg_start.mem", msg_start, 8)
    wmem("msg_arity.mem", msg_arity, 8)

    _write_sv_header(outdir, uop, lit_pool, str_pool, str_table, msg_start, bad_uop_id)
    _write_vhdl_pkg(outdir, uop, lit_pool, str_pool, str_table, msg_start, bad_uop_id)
    _write_gold_inc(outdir, msg_meta)
    _write_report(outdir, msg_meta, uop, lit_pool)
    vecs = _write_vectors(outdir, msg_meta, n_random=n_random, seed=seed)

    return {
        "n_msgs": len(msg_meta), "n_uops": len(uop),
        "lit_bytes": len(lit_pool), "str_bytes": len(str_pool),
        "n_vectors": vecs, "meta": msg_meta, "bad_uop_id": bad_uop_id,
    }


def _write_sv_header(outdir, uop, lit, spool, stab, mstart, bad_id):
    with open(os.path.join(outdir, "kp_msgs.svh"), "w") as f:
        f.write("// GENERATED by tools/k_fmtgen.py - do not edit.\n")
        f.write("`ifndef KP_MSGS_SVH\n`define KP_MSGS_SVH\n")
        f.write("localparam int KP_ISA_VERSION = %d;\n" % KP_ISA_VERSION)
        f.write("localparam int KP_N_MSGS   = %d;\n" % len(mstart))
        f.write("localparam int KP_N_UOPS   = %d;\n" % len(uop))
        f.write("localparam int KP_LIT_BYTES = %d;\n" % len(lit))
        f.write("localparam int KP_STR_BYTES = %d;\n" % len(spool))
        f.write("localparam int KP_N_STRINGS = %d;\n" % len(stab))
        f.write("localparam int KP_BAD_UOP_MSG_ID = %d;\n" % bad_id)
        f.write("`endif\n")


def _write_vhdl_pkg(outdir, uop, lit, spool, stab, mstart, bad_id):
    with open(os.path.join(outdir, "kp_msgs_pkg.vhd"), "w") as f:
        f.write("-- GENERATED by tools/k_fmtgen.py - do not edit.\n")
        f.write("package kp_msgs_pkg is\n")
        f.write("  constant KP_ISA_VERSION : integer := %d;\n" % KP_ISA_VERSION)
        f.write("  constant KP_N_MSGS    : integer := %d;\n" % len(mstart))
        f.write("  constant KP_N_UOPS    : integer := %d;\n" % len(uop))
        f.write("  constant KP_LIT_BYTES : integer := %d;\n" % len(lit))
        f.write("  constant KP_STR_BYTES : integer := %d;\n" % len(spool))
        f.write("  constant KP_N_STRINGS : integer := %d;\n" % len(stab))
        f.write("  constant KP_BAD_UOP_MSG_ID : integer := %d;\n" % bad_id)
        f.write("end package;\n")


def _write_gold_inc(outdir, meta):
    """Per-message dispatch: kp_gold calls the real k_snprintf with correctly
    typed args, so the oracle bytes come from the actual C library."""
    with open(os.path.join(outdir, "kp_gold.inc"), "w") as f:
        f.write("/* GENERATED by tools/k_fmtgen.py - do not edit. */\n")
        f.write("/* int kp_gold(int msg_id, const uint32_t *a, char *buf, size_t sz) */\n")
        f.write("static const char *kp_strtab[%d] = {\n" % len(STRING_TABLE))
        for idx, s in enumerate(STRING_TABLE):
            if idx == 0:
                f.write("    (const char *)0, /* id 0 -> NULL, exercises (null) */\n")
            else:
                f.write('    "%s",\n' % s)
        f.write("};\n")
        f.write("static int kp_gold(int msg_id, const uint32_t *a, char *buf, size_t sz){\n")
        f.write("  (void)a;\n  switch(msg_id){\n")
        for mid, (sym, fmt, argtypes) in enumerate(meta):
            if fmt is None:
                continue          # bad-uop test message: no golden
            call_args = []
            for k, t in enumerate(argtypes):
                if t in ("int", "int*w", "int*p"):
                    call_args.append("(int)a[%d]" % k)
                elif t == "unsigned":
                    call_args.append("(unsigned)a[%d]" % k)
                elif t == "long":
                    call_args.append("(long)(int32_t)a[%d]" % k)
                elif t == "unsigned long":
                    call_args.append("(unsigned long)a[%d]" % k)
                elif t == "ptr":
                    call_args.append("(void*)(uintptr_t)a[%d]" % k)
                elif t == "str":
                    # ISA rule: id = low 16 bits mod table size (both RTLs ditto)
                    call_args.append("kp_strtab[(a[%d] & 0xFFFFu) %% %d]"
                                     % (k, len(STRING_TABLE)))
            cfmt = c_escape(fmt)
            f.write('    case %d: return k_snprintf(buf, sz, "%s"%s);\n'
                    % (mid, cfmt, "".join(", " + x for x in call_args)))
        f.write("    default: return -1;\n  }\n}\n")


def c_escape(s):
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif 32 <= ord(ch) < 127:
            out.append(ch)
        else:
            out.append("\\x%02x" % ord(ch))
    return "".join(out)


# deterministic LCG so vectors are reproducible for a given seed
class Rng:
    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFF

    def next(self):
        self.s = (1103515245 * self.s + 12345) & 0xFFFFFFFF
        return self.s

    def rint(self, lo, hi):
        return lo + (self.next() % (hi - lo + 1))


def _sx32(v):
    return v & 0xFFFFFFFF


def _arg_value(rng, t, directed_idx):
    """Pick an argument word for type t. No-`l` numeric args are constrained to
    16-bit range (plan 2.1); '*' args to the supported field range."""
    directed16 = [0, 1, 0x7FFF, 0x8000, 0xFFFF, 42, 255]
    directed32 = [0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xDEADBEEF, 1000000]
    directed_w = [0, G_MAX_FIELD, -G_MAX_FIELD, 5, -7, 1]
    directed_p = [0, G_MAX_FIELD, -1, 3, 8, 1]
    if t == "int*w":              # signed, |w| <= 63 (negative -> left-justify)
        v = directed_w[directed_idx % len(directed_w)] if directed_idx >= 0 \
            else rng.rint(-G_MAX_FIELD, G_MAX_FIELD)
        return _sx32(v)
    if t == "int*p":              # signed, -8..63 (negative -> no precision)
        v = directed_p[directed_idx % len(directed_p)] if directed_idx >= 0 \
            else rng.rint(-8, G_MAX_FIELD)
        return _sx32(v)
    if t == "int":                # signed 16-bit range, sign-extended
        v = directed16[directed_idx % len(directed16)] if directed_idx >= 0 else rng.rint(0, 0xFFFF)
        if v & 0x8000:
            v |= 0xFFFF0000
        return _sx32(v)
    if t == "unsigned":
        return (directed16[directed_idx % len(directed16)] if directed_idx >= 0
                else rng.rint(0, 0xFFFF))
    if t == "long":
        v = directed32[directed_idx % len(directed32)] if directed_idx >= 0 else rng.next()
        return _sx32(v)
    if t in ("unsigned long", "ptr"):
        return _sx32(directed32[directed_idx % len(directed32)] if directed_idx >= 0
                     else rng.next())
    if t == "str":
        return (directed_idx % len(STRING_TABLE)) if directed_idx >= 0 \
            else rng.rint(0, len(STRING_TABLE) - 1)
    return 0


def _write_vectors(outdir, meta, n_random=8, seed=0xC0FFEE):
    """Emit 'msg_id nargs a0..' lines (args 8-nibble hex): directed then random.
    The bad-uop test message is excluded (it has no golden output)."""
    rng = Rng(seed)
    rows = []
    for mid, (sym, fmt, argtypes) in enumerate(meta):
        if fmt is None:
            continue
        for d in range(4):
            rows.append((mid, [_arg_value(rng, t, d) for t in argtypes]))
        for _ in range(n_random):
            rows.append((mid, [_arg_value(rng, t, -1) for t in argtypes]))
    with open(os.path.join(outdir, "vectors.txt"), "w") as f:
        for mid, args in rows:
            f.write("%d %d %s\n" % (mid, len(args), " ".join("%08x" % x for x in args)))
    return len(rows)


def _write_report(outdir, meta, uop, lit):
    with open(os.path.join(outdir, "messages_report.md"), "w") as f:
        f.write("# k_printf_hdl message inventory (GENERATED)\n\n")
        f.write("ISA v%d - %d messages (last = malformed-uop test), %d uop words "
                "(incl. header), %d literal bytes.\n\n"
                % (KP_ISA_VERSION, len(meta), len(uop), len(lit)))
        f.write("| id | symbol | arity | format |\n|----|--------|-------|--------|\n")
        for mid, (sym, fmt, argtypes) in enumerate(meta):
            shown = "(malformed-uop test message)" if fmt is None else \
                fmt.replace("\r", "\\r").replace("\n", "\\n").replace("|", "\\|")
            f.write("| %d | `%s` | %d | `%s` |\n" % (mid, sym, len(argtypes), shown))


def main():
    ap = argparse.ArgumentParser(description="Compile messages.h into k_printf_hdl artifacts")
    ap.add_argument("messages", help="path to messages.h")
    ap.add_argument("-o", "--outdir", required=True, help="output directory")
    ap.add_argument("--seed", type=lambda x: int(x, 0), default=0xC0FFEE,
                    help="RNG seed for the random vectors (default 0xC0FFEE)")
    ap.add_argument("--nrandom", type=int, default=8,
                    help="random vectors per message (default 8)")
    args = ap.parse_args()
    try:
        msgs = read_messages(args.messages)
        info = generate(msgs, args.outdir, seed=args.seed, n_random=args.nrandom)
    except FmtError as e:
        print("k_fmtgen: error: %s" % e, file=sys.stderr)
        return 2
    print("k_fmtgen: %d messages -> %d uops, %d lit bytes, %d str bytes, "
          "%d vectors (ISA v%d, seed 0x%x)"
          % (info["n_msgs"], info["n_uops"], info["lit_bytes"], info["str_bytes"],
             info["n_vectors"], KP_ISA_VERSION, args.seed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
