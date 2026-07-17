/*
 * k_printf v2.0 - lightweight freestanding printf.
 * See include/k_printf.h and README.md. MIT licensed.
 */
#include "k_printf.h"
#include <stdint.h>   /* uintptr_t (for %p) */
#include <limits.h>   /* CHAR_BIT (digit buffer sizing) */

_Static_assert(sizeof(unsigned long) * CHAR_BIT >= 32,
               "k_printf promises 32-bit output via %l on every target");

/* ---- Compile-time feature switches (opt-in via -D...=0 to shrink ROM) --- */
/* The d/i/u/c/s/%% core is always built. The rest can be dropped. When a
 * specifier is disabled it is echoed literally and does NOT consume an arg. */
#ifndef K_PRINTF_ENABLE_LONG
#define K_PRINTF_ENABLE_LONG 1   /* %ld %lu %lx %lX %lo %lb */
#endif
#ifndef K_PRINTF_ENABLE_HEX
#define K_PRINTF_ENABLE_HEX 1    /* %x %X */
#endif
#ifndef K_PRINTF_ENABLE_OCTAL
#define K_PRINTF_ENABLE_OCTAL 1  /* %o */
#endif
#ifndef K_PRINTF_ENABLE_BIN
#define K_PRINTF_ENABLE_BIN 1    /* %b %B (C23-style binary) */
#endif
#ifndef K_PRINTF_ENABLE_PTR
#define K_PRINTF_ENABLE_PTR 1    /* %p */
#endif

/* ---- Formatting flags -------------------------------------------------- */
#define FLAG_ZERO  0x01u  /* '0' */
#define FLAG_LEFT  0x02u  /* '-' */
#define FLAG_PLUS  0x04u  /* '+' */
#define FLAG_SPACE 0x08u  /* ' ' */
#define FLAG_HASH  0x10u  /* '#' */

/* Output state threaded through the formatter; keeps a running char count. */
typedef struct {
    k_putc_fn putc;
    void     *userdata;
    int       count;
} k_out_t;

static void emit(k_out_t *o, char c) {
    o->putc(c, o->userdata);
    o->count++;
}

static void emit_pad(k_out_t *o, char c, int n) {
    while (n-- > 0) {
        emit(o, c);
    }
}

/*
 * Formats one unsigned magnitude `uv` in `base` with printf-style width,
 * precision and flags. `neg` requests a leading '-'. `upper` selects
 * uppercase hex/binary digits. The tmp buffer is sized from the type: worst
 * case is base 2, one digit per bit of `unsigned long`.
 */
static void fmt_int(k_out_t *o, unsigned long uv, unsigned base, int upper,
                    int neg, unsigned flags, int width, int precision) {
    static const char lower[] = "0123456789abcdef";
    static const char upperd[] = "0123456789ABCDEF";
    const char *digits = upper ? upperd : lower;
    char tmp[sizeof(unsigned long) * CHAR_BIT];
    int ndigits = 0;
    int is_zero = (uv == 0UL);

    /* precision 0 with value 0 => no digits at all */
    if (!(precision == 0 && is_zero)) {
        /* One division per digit: derive the remainder from the quotient so
         * targets without hardware divide (MSP430) call the software divide
         * helper once, not twice, per digit. */
        do {
            unsigned long q = uv / base;
            tmp[ndigits++] = digits[(unsigned)(uv - q * base)];
            uv = q;
        } while (uv != 0UL);
    }

    /* precision = minimum number of digits (zero-filled) */
    int lead_zeros = (precision > ndigits) ? (precision - ndigits) : 0;

    /* sign / space / plus (mutually exclusive; '-' wins) */
    char sign = 0;
    if (neg)                     sign = '-';
    else if (flags & FLAG_PLUS)  sign = '+';
    else if (flags & FLAG_SPACE) sign = ' ';

    /* alternate-form prefix from '#' */
    char pfx0 = 0, pfx1 = 0;
    int plen = 0;
    if (flags & FLAG_HASH) {
        if (base == 16 && !is_zero) { pfx0 = '0'; pfx1 = upper ? 'X' : 'x'; plen = 2; }
        else if (base == 2 && !is_zero) { pfx0 = '0'; pfx1 = upper ? 'B' : 'b'; plen = 2; }
        else if (base == 8) {
            /* Force a leading zero unless one is already first (C11 7.21.6.1:
             * "%#.0o" of 0 still prints a single "0"). */
            if (lead_zeros == 0 && !(ndigits > 0 && tmp[ndigits - 1] == '0'))
                lead_zeros = 1;
        }
    }

    /* fixed part is tiny (sign+prefix+digits); only lead_zeros (driven by a
     * caller-supplied precision up to INT_MAX) can overflow the sum */
    int fixed = (sign ? 1 : 0) + plen + ndigits;
    int body = (lead_zeros > INT_MAX - fixed) ? INT_MAX : fixed + lead_zeros;
    int pad = (width > body) ? (width - body) : 0;

    if (flags & FLAG_LEFT) {                 /* left-justify: pad spaces after */
        if (sign) emit(o, sign);
        if (plen) { emit(o, pfx0); emit(o, pfx1); }
        emit_pad(o, '0', lead_zeros);
        while (ndigits) emit(o, tmp[--ndigits]);
        emit_pad(o, ' ', pad);
    } else if ((flags & FLAG_ZERO) && precision < 0) { /* zero-pad after sign/prefix */
        if (sign) emit(o, sign);
        if (plen) { emit(o, pfx0); emit(o, pfx1); }
        emit_pad(o, '0', pad + lead_zeros);
        while (ndigits) emit(o, tmp[--ndigits]);
    } else {                                 /* right-justify with spaces */
        emit_pad(o, ' ', pad);
        if (sign) emit(o, sign);
        if (plen) { emit(o, pfx0); emit(o, pfx1); }
        emit_pad(o, '0', lead_zeros);
        while (ndigits) emit(o, tmp[--ndigits]);
    }
}

/* Signed integer: compute magnitude without ever negating a signed value
 * (avoids INT_MIN/LONG_MIN overflow UB). */
static void fmt_signed(k_out_t *o, long sv, unsigned flags, int width, int precision) {
    int neg = 0;
    unsigned long uv;
    if (sv < 0) { neg = 1; uv = 0UL - (unsigned long)sv; }
    else        {          uv = (unsigned long)sv; }
    fmt_int(o, uv, 10, 0, neg, flags, width, precision);
}

/* %s with precision (max length) and width padding. NULL -> "(null)". */
static void fmt_str(k_out_t *o, const char *s, unsigned flags, int width, int precision) {
    if (!s) s = "(null)";
    int len = 0;
    while (s[len] != '\0' && (precision < 0 || len < precision)) len++;
    int pad = (width > len) ? (width - len) : 0;
    if (flags & FLAG_LEFT) {
        for (int i = 0; i < len; i++) emit(o, s[i]);
        emit_pad(o, ' ', pad);
    } else {
        emit_pad(o, ' ', pad);
        for (int i = 0; i < len; i++) emit(o, s[i]);
    }
}

int k_vprintf_cb(k_putc_fn putc, void *userdata, const char *fmt, va_list ap) {
    if (!putc || !fmt) return K_PRINTF_ERR;
    k_out_t o;
    o.putc = putc;
    o.userdata = userdata;
    o.count = 0;

    while (*fmt) {
        if (*fmt != '%') { emit(&o, *fmt++); continue; }
        fmt++;                       /* consume '%' */
        if (*fmt == '\0') break;     /* lone trailing '%' -> drop, no OOB read */

        /* ---- flags ---- */
        unsigned flags = 0;
        for (;;) {
            char f = *fmt;
            if      (f == '0') flags |= FLAG_ZERO;
            else if (f == '-') flags |= FLAG_LEFT;
            else if (f == '+') flags |= FLAG_PLUS;
            else if (f == ' ') flags |= FLAG_SPACE;
            else if (f == '#') flags |= FLAG_HASH;
            else break;
            fmt++;
        }

        /* ---- width (decimal or '*') ---- */
        int width = 0;
        if (*fmt == '*') {
            int w = va_arg(ap, int);
            /* negative '*' width = '-' flag + positive width; negate without
             * signed-overflow UB on INT_MIN (saturate to INT_MAX) */
            if (w < 0) { flags |= FLAG_LEFT; width = (w == INT_MIN) ? INT_MAX : -w; }
            else       { width = w; }
            fmt++;
        } else {
            /* saturating accumulate: a silly-large literal width must not
             * overflow int (16-bit on MSP430: "%32768d" would already UB) */
            while (*fmt >= '0' && *fmt <= '9') {
                int d = *fmt++ - '0';
                width = (width > (INT_MAX - d) / 10) ? INT_MAX : width * 10 + d;
            }
        }

        /* ---- precision (.decimal or .*) ---- */
        int precision = -1;
        if (*fmt == '.') {
            fmt++;
            precision = 0;
            if (*fmt == '*') {
                int p = va_arg(ap, int);
                precision = (p < 0) ? -1 : p;
                fmt++;
            } else {
                while (*fmt >= '0' && *fmt <= '9') {
                    int d = *fmt++ - '0';
                    precision = (precision > (INT_MAX - d) / 10) ? INT_MAX
                                                                 : precision * 10 + d;
                }
            }
        }

        /* ---- length modifier (l/ll accepted; h/hh parsed and ignored) ----
         * With LONG disabled the 'l' is NOT consumed, so "%ld" falls into the
         * unknown-specifier path: echoed literally, no vararg read - keeping
         * the documented disabled-specifier contract (no stream desync). */
        int is_long = 0;
#if K_PRINTF_ENABLE_LONG
        while (*fmt == 'l') { is_long = 1; fmt++; }
#endif
        while (*fmt == 'h') { fmt++; }

        char spec = *fmt;
        if (spec == '\0') break;     /* malformed: '%' + modifiers + end */
        fmt++;

        switch (spec) {
        case 'd':
        case 'i':
            fmt_signed(&o, is_long ? va_arg(ap, long) : (long)va_arg(ap, int),
                       flags, width, precision);
            break;
        case 'u':
            fmt_int(&o, is_long ? va_arg(ap, unsigned long)
                                : (unsigned long)va_arg(ap, unsigned int),
                    10, 0, 0, flags, width, precision);
            break;
#if K_PRINTF_ENABLE_HEX
        case 'x':
        case 'X':
            fmt_int(&o, is_long ? va_arg(ap, unsigned long)
                                : (unsigned long)va_arg(ap, unsigned int),
                    16, spec == 'X', 0, flags, width, precision);
            break;
#endif
#if K_PRINTF_ENABLE_OCTAL
        case 'o':
            fmt_int(&o, is_long ? va_arg(ap, unsigned long)
                                : (unsigned long)va_arg(ap, unsigned int),
                    8, 0, 0, flags, width, precision);
            break;
#endif
#if K_PRINTF_ENABLE_BIN
        case 'b':
        case 'B':
            fmt_int(&o, is_long ? va_arg(ap, unsigned long)
                                : (unsigned long)va_arg(ap, unsigned int),
                    2, spec == 'B', 0, flags, width, precision);
            break;
#endif
#if K_PRINTF_ENABLE_PTR
        case 'p': {
            unsigned long uv = (unsigned long)(uintptr_t)va_arg(ap, void *);
            fmt_int(&o, uv, 16, 0, 0, flags | FLAG_HASH, width, precision);
            break;
        }
#endif
        case 'c': {
            char c = (char)va_arg(ap, int);
            int pad = (width > 1) ? (width - 1) : 0;
            if (flags & FLAG_LEFT) { emit(&o, c); emit_pad(&o, ' ', pad); }
            else                   { emit_pad(&o, ' ', pad); emit(&o, c); }
            break;
        }
        case 's':
            fmt_str(&o, va_arg(ap, const char *), flags, width, precision);
            break;
        case '%':
            emit(&o, '%');
            break;
        default:
            /* Unknown specifier: echo literally. Deliberately does NOT read a
             * vararg, so callers are warned but the vararg stream stays aligned
             * for the remaining conversions. */
            emit(&o, '%');
            emit(&o, spec);
            break;
        }
    }
    return o.count;
}

/* ---- Global sink + classic API ----------------------------------------- */
static k_putc_fn g_putc = 0;
static void     *g_userdata = 0;

/* Critical-section hooks around the global-sink path. The defaults are no-ops
 * with weak linkage: override them (no header change needed) to serialize
 * whole messages, e.g. against an ISR that also logs. See examples/. */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((weak)) void k_printf_lock(void)   {}
__attribute__((weak)) void k_printf_unlock(void) {}
#else
void k_printf_lock(void)   {}
void k_printf_unlock(void) {}
#endif

void k_printf_init(k_putc_fn putc, void *userdata) {
    if (!putc) return;            /* reject NULL: keep the previous sink */
    g_putc = putc;
    g_userdata = userdata;
}

int k_vprintf(const char *fmt, va_list ap) {
    if (!g_putc) return K_PRINTF_ERR;
    k_printf_lock();
    int r = k_vprintf_cb(g_putc, g_userdata, fmt, ap);
    k_printf_unlock();
    return r;
}

int k_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = k_vprintf(fmt, ap);
    va_end(ap);
    return r;
}

/* ---- Explicit-sink API -------------------------------------------------- */
int k_vfprintf(const k_printf_sink_t *sink, const char *fmt, va_list ap) {
    if (!sink || !sink->putc) return K_PRINTF_ERR;
    return k_vprintf_cb(sink->putc, sink->userdata, fmt, ap);
}

int k_fprintf(const k_printf_sink_t *sink, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = k_vfprintf(sink, fmt, ap);
    va_end(ap);
    return r;
}

/* ---- Buffer (snprintf) variants ---------------------------------------- */
typedef struct {
    char  *buf;
    size_t size;
    size_t idx;
} k_buf_t;

static void buf_putc(char c, void *ud) {
    k_buf_t *b = (k_buf_t *)ud;
    if (b->idx + 1 < b->size) {   /* always leave room for the NUL */
        b->buf[b->idx] = c;
    }
    b->idx++;
}

int k_vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    k_buf_t b;
    b.buf = buf;
    b.size = size;
    b.idx = 0;
    int n = k_vprintf_cb(buf_putc, &b, fmt, ap);
    if (size > 0) {
        size_t term = (b.idx < size) ? b.idx : size - 1;
        buf[term] = '\0';
    }
    return n;
}

int k_snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = k_vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return r;
}
