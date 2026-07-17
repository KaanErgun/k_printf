/*
 * Differential fuzzer: k_snprintf vs the host snprintf, restricted to the
 * format subset both implement with identical, fully-defined semantics
 * (%d %i %u %x %X %o %c %s %% with -/+/space/0/# flags, width, precision,
 * '*' and the 'l' modifier). %b/%B, %p, NULL %s and unknown specifiers are
 * deliberately excluded: they have no snprintf oracle.
 *
 * The input bytes are decoded into (flags, width, precision, spec, value,
 * literal text) rather than used as a raw format string, so every generated
 * format is defined behaviour for BOTH implementations and any difference is
 * a real bug in k_printf.
 *
 * Build as a libFuzzer target (clang):
 *   clang -std=c11 -g -fsanitize=fuzzer,address,undefined -Iinclude \
 *         src/k_printf.c tests/fuzz_k_printf.c -o build/fuzz
 * Build standalone (any cc; Apple clang has no libFuzzer):
 *   cc -std=c11 -g -fsanitize=address,undefined -DFUZZ_STANDALONE -Iinclude \
 *      src/k_printf.c tests/fuzz_k_printf.c -o build/fuzz_standalone
 *   ./build/fuzz_standalone [iterations]   (default 200000, fixed seed)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include "k_printf.h"

#define MAX_WIDTH 40
#define MAX_PREC  40
#define LIT_MAX   24

/* Argument class implied by the conversion specifier. */
enum arg_class { ARG_INT, ARG_LONG, ARG_UINT, ARG_ULONG, ARG_CHAR, ARG_STR };

static void fail(const char *fmt, const char *kout, const char *sout,
                 int rk, int rs) {
    fprintf(stderr,
            "MISMATCH fmt=\"%s\"\n  k_snprintf -> %d \"%s\"\n"
            "  snprintf   -> %d \"%s\"\n", fmt, rk, kout, rs, sout);
    abort();
}

/* Run both implementations on the same (fmt, arg); abort on any difference. */
#define DIFF(...) do {                                                       \
    int rk = k_snprintf(kout, sizeof kout, __VA_ARGS__);                     \
    int rs = snprintf(sout, sizeof sout, __VA_ARGS__);                       \
    if (rk != rs || strcmp(kout, sout) != 0) fail(fmt, kout, sout, rk, rs);  \
} while (0)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 8) return 0;

    char fmt[128];
    char kout[512], sout[512];
    size_t fi = 0;

    /* ---- decode the conversion from the first 8 bytes ---- */
    const uint8_t fl = data[0], wb = data[1], pb = data[2], sb = data[3];
    const uint32_t v = (uint32_t)data[4] | ((uint32_t)data[5] << 8) |
                       ((uint32_t)data[6] << 16) | ((uint32_t)data[7] << 24);

    static const char specs[] = "diuxXocs%";
    const char spec = specs[sb % (sizeof specs - 1)];
    const int is_long = (sb & 0x80) &&
                        (spec == 'd' || spec == 'i' || spec == 'u' ||
                         spec == 'x' || spec == 'X' || spec == 'o');
    const int is_signed   = (spec == 'd' || spec == 'i');
    const int is_altable  = (spec == 'x' || spec == 'X' || spec == 'o');
    const int has_prec    = (pb & 0x40) && spec != 'c' && spec != '%';
    const int star_width  = wb & 0x80;   /* pass width via '*' */
    const int star_prec   = pb & 0x80;   /* pass precision via '.*' */
    int width = wb % (MAX_WIDTH + 1);
    int prec  = pb % (MAX_PREC + 1);

    /* ---- literal text around the conversion (printable, no '%') ---- */
    char lit[2 * LIT_MAX + 2];
    size_t nlit = 0;
    for (size_t i = 8; i < size && nlit < sizeof lit - 1; i++) {
        char c = (char)(0x20 + (data[i] % 95));   /* printable ASCII */
        if (c != '%') lit[nlit++] = c;
    }
    lit[nlit] = '\0';
    const size_t cut = nlit / 2;

    /* ---- assemble the format string ---- */
    memcpy(fmt, lit, cut); fi = cut;
    fmt[fi++] = '%';
    if (spec != '%') {
        /* Only emit flags that are defined behaviour for this conversion. */
        if (fl & 0x01) fmt[fi++] = '-';
        if ((fl & 0x02) && is_signed) fmt[fi++] = '+';
        if ((fl & 0x04) && is_signed) fmt[fi++] = ' ';
        if ((fl & 0x08) && spec != 'c' && spec != 's') fmt[fi++] = '0';
        if ((fl & 0x10) && is_altable) fmt[fi++] = '#';
        if (wb & 0x40) {
            if (star_width) { fmt[fi++] = '*'; }
            /* a literal width of 0 must be OMITTED: the digit '0' in flag
             * position would parse as the zero flag, which is UB for %c/%s */
            else if (width > 0) fi += (size_t)snprintf(fmt + fi, 4, "%d", width);
        } else {
            width = 0; /* no width in the format */
        }
        if (has_prec) {
            fmt[fi++] = '.';
            if (star_prec) { fmt[fi++] = '*'; }
            else fi += (size_t)snprintf(fmt + fi, 4, "%d", prec);
        }
        if (is_long) fmt[fi++] = 'l';
    }
    fmt[fi++] = spec;   /* for spec '%' this completes a well-formed "%%" */
    memcpy(fmt + fi, lit + cut, nlit - cut); fi += nlit - cut;
    fmt[fi] = '\0';

    /* ---- argument material ---- */
    char sarg[LIT_MAX + 1];
    memcpy(sarg, lit, (nlit < LIT_MAX) ? nlit : LIT_MAX);
    sarg[(nlit < LIT_MAX) ? nlit : LIT_MAX] = '\0';
    const int  carg = 0x20 + (int)(v % 95u);          /* printable char */
    const long lv   = (long)(int32_t)v;

    enum arg_class cls =
        (spec == 'c') ? ARG_CHAR :
        (spec == 's') ? ARG_STR  :
        is_signed     ? (is_long ? ARG_LONG  : ARG_INT)  :
        (spec == '%') ? ARG_INT  :
                        (is_long ? ARG_ULONG : ARG_UINT);

    /* Emit every combination of (star width) x (star precision) the decoded
     * conversion asked for. Extra trailing args are harmless per C11. */
    if (star_width && (wb & 0x40)) {
        int w = (fl & 0x20) ? -width : width;   /* negative '*' width too */
        if (star_prec && has_prec) {
            switch (cls) {
            case ARG_INT:   DIFF(fmt, w, prec, (int)v);          break;
            case ARG_LONG:  DIFF(fmt, w, prec, lv);              break;
            case ARG_UINT:  DIFF(fmt, w, prec, (unsigned)v);     break;
            case ARG_ULONG: DIFF(fmt, w, prec, (unsigned long)v);break;
            case ARG_CHAR:  DIFF(fmt, w, prec, carg);            break;
            case ARG_STR:   DIFF(fmt, w, prec, sarg);            break;
            }
        } else {
            switch (cls) {
            case ARG_INT:   DIFF(fmt, w, (int)v);           break;
            case ARG_LONG:  DIFF(fmt, w, lv);               break;
            case ARG_UINT:  DIFF(fmt, w, (unsigned)v);      break;
            case ARG_ULONG: DIFF(fmt, w, (unsigned long)v); break;
            case ARG_CHAR:  DIFF(fmt, w, carg);             break;
            case ARG_STR:   DIFF(fmt, w, sarg);             break;
            }
        }
    } else if (star_prec && has_prec) {
        switch (cls) {
        case ARG_INT:   DIFF(fmt, prec, (int)v);           break;
        case ARG_LONG:  DIFF(fmt, prec, lv);               break;
        case ARG_UINT:  DIFF(fmt, prec, (unsigned)v);      break;
        case ARG_ULONG: DIFF(fmt, prec, (unsigned long)v); break;
        case ARG_CHAR:  DIFF(fmt, prec, carg);             break;
        case ARG_STR:   DIFF(fmt, prec, sarg);             break;
        }
    } else {
        switch (cls) {
        case ARG_INT:   DIFF(fmt, (int)v);           break;
        case ARG_LONG:  DIFF(fmt, lv);               break;
        case ARG_UINT:  DIFF(fmt, (unsigned)v);      break;
        case ARG_ULONG: DIFF(fmt, (unsigned long)v); break;
        case ARG_CHAR:  DIFF(fmt, carg);             break;
        case ARG_STR:   DIFF(fmt, sarg);             break;
        }
    }
    return 0;
}

#ifdef FUZZ_STANDALONE
/* Self-driving mode for toolchains without libFuzzer (e.g. Apple clang):
 * replays any files given on argv, then hammers the target with
 * deterministic xorshift-generated inputs. */
static uint32_t xorshift32(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return *s = x;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {              /* replay corpus files */
        FILE *f = fopen(argv[i], "rb");
        if (!f) continue;
        uint8_t buf[4096];
        size_t nn = fread(buf, 1, sizeof buf, f);
        fclose(f);
        LLVMFuzzerTestOneInput(buf, nn);
    }

    long iters = 200000;
    if (argc > 1) {
        long a = strtol(argv[argc - 1], NULL, 10);
        if (a > 0) iters = a;
    }
    uint32_t seed = 0xC0FFEEu;
    uint8_t buf[64];
    for (long it = 0; it < iters; it++) {
        size_t len = 8 + (xorshift32(&seed) % (sizeof buf - 8));
        for (size_t i = 0; i < len; i += 4) {
            uint32_t r = xorshift32(&seed);
            for (size_t j = 0; j < 4 && i + j < len; j++)
                buf[i + j] = (uint8_t)(r >> (8 * j));
        }
        LLVMFuzzerTestOneInput(buf, len);
    }
    printf("fuzz-standalone: %ld deterministic inputs, no differences\n", iters);
    return 0;
}
#endif
