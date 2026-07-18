/*
 * messages_min.h - reduced message set for the G_EN_* opt-out config test.
 *
 * Uses only literals, hex and %c: compiled with
 *   k_fmtgen.py --disable dec,oct,bin,str,ptr
 * and simulated against a core elaborated with G_EN_DEC=0, G_EN_STR=0 - the
 * hardware analogue of the C library's tests/test_optout.c configuration
 * build. Any message here that slips in a disabled feature fails generation.
 */

/* K_MSG(symbol, format) */
K_MSG(MSG_MIN_BOOT,  "min core up\r\n")
K_MSG(MSG_MIN_REG,   "reg=%#06x\r\n")
K_MSG(MSG_MIN_PAIR,  "[%04X][%-6x][%3c]\r\n")
K_MSG(MSG_MIN_WIDE,  "%08X:% x\r\n")
