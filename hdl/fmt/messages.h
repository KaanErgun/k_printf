/*
 * messages.h - single source of truth for the k_printf_hdl example message set.
 *
 * Each K_MSG(SYMBOL, "format") is one compile-time message. tools/k_fmtgen.py
 * parses the format, derives the argument count and per-argument type, and emits:
 *   - the µop ROM + literal/string pools (consumed by the SV and VHDL cores),
 *   - the message-id / arity / string tables,
 *   - the C golden dispatch (kp_gold calls the real k_snprintf per message),
 *   - directed + seeded-random test vectors.
 *
 * The same header is #included by the C golden harness (hdl/gold/kp_gold.c), so the
 * format strings the hardware is compiled from and the ones the oracle prints are
 * physically the same text - no drift possible.
 *
 * Supported (ISA v2): specifiers % c s d i u x X o b B p, flags - 0 # + space,
 * field width and .precision 0..63 (literal or '*' from an argument), and the
 * l (32-bit) length modifier; h/hh are accepted and ignored (C mirror).
 * Precision on %c is rejected (C-undefined). See docs/hdl/fmt_isa.md.
 */

/* K_MSG(symbol, format) */
K_MSG(MSG_BOOT,      "k_printf_hdl v%d.%d ready\r\n")
K_MSG(MSG_HELLO,     "hello, hardware printf\r\n")
K_MSG(MSG_PERCENT,   "duty %u%% ok\r\n")
K_MSG(MSG_REG,       "reg = %#06x\r\n")
K_MSG(MSG_REGU,      "REG = %#010lX\r\n")
K_MSG(MSG_TICK,      "tick=%lu\r\n")
K_MSG(MSG_SIGNED,    "delta = %d (%+d)\r\n")
K_MSG(MSG_NEGpad,    "[%6d][%-6d][%06d]\r\n")
K_MSG(MSG_PORT,      "port %08b oct %#o\r\n")
K_MSG(MSG_BYTES,     "%02x:%02x:%02x:%02x\r\n")
K_MSG(MSG_ADDR,      "addr %p len %u\r\n")
K_MSG(MSG_CHAR,      "grade [%c] [%3c] [%-3c]\r\n")
K_MSG(MSG_NAME,      "unit: %s / %8s / %-8s\r\n")
K_MSG(MSG_MIX,       "%s=%d 0x%04X %b%%\r\n")
K_MSG(MSG_SPACE,     "t=% d c=%c\r\n")

/* precision / '*' / h-modifier torture set (ISA v2) */
K_MSG(MSG_PREC,      "[%.4d][%8.3d][%-8.3d][%08.3d]\r\n")
K_MSG(MSG_PREC0,     "[%.0d][%3.0u][%#.0o][%.d]\r\n")
K_MSG(MSG_PRECX,     "[%.5x][%#.5X][%.2b][%#.1o]\r\n")
K_MSG(MSG_SPREC,     "%.3s|%6.2s|%-6.4s|\r\n")
K_MSG(MSG_STARW,     "[%*d][%-*u][%*c]\r\n")
K_MSG(MSG_STARP,     "[%.*d][%.*s]\r\n")
K_MSG(MSG_STARWP,    "[%*.*d][%*.*s]\r\n")
K_MSG(MSG_LPREC,     "[%12.6ld][%.8lx][%+.4d]\r\n")
K_MSG(MSG_HMOD,      "h=%hd hh=%hhu\r\n")
/* '+'/' ' on unsigned: the C library's documented deviation from ISO C - the
 * cores mirror it, and this message pins the behaviour differentially. */
K_MSG(MSG_SIGNU,     "[%+u][% x][%+8o][% b]\r\n")
