/*
 * k_printf - lightweight, freestanding printf for MSP430 and other small MCUs.
 *
 * v2.0 - no malloc, no libc printf, no format buffer required. The core
 * (k_vprintf_cb) is global-stateless and reentrant; output goes through a
 * user-supplied putc callback.
 *
 * MSP430 note: `int`/`unsigned` are 16-bit, `long` is 32-bit. Use the `l`
 * length modifier (%ld/%lu/%lx) to print 32-bit values.
 *
 * License: MIT (see LICENSE).
 */
#ifndef K_PRINTF_H
#define K_PRINTF_H

#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Versioning (SemVer) ------------------------------------------------ */
#define K_PRINTF_VERSION_MAJOR 2
#define K_PRINTF_VERSION_MINOR 0
#define K_PRINTF_VERSION_PATCH 0
#define K_PRINTF_VERSION       (K_PRINTF_VERSION_MAJOR * 10000 + \
                                K_PRINTF_VERSION_MINOR * 100   + \
                                K_PRINTF_VERSION_PATCH)          /* 20000 */
#define K_PRINTF_VERSION_STRING "2.0.0"

/* Returned on error (NULL sink / NULL format). */
#define K_PRINTF_ERR (-1)

/*
 * Character-output callback.
 *   c        - the byte to emit.
 *   userdata - opaque pointer registered with the sink / init (may be NULL).
 * The callback must block until the byte is accepted (e.g. UART TX ready).
 */
typedef void (*k_putc_fn)(char c, void *userdata);

/* An explicit output target: a callback plus its userdata. */
typedef struct {
    k_putc_fn putc;
    void     *userdata;
} k_printf_sink_t;

/* ---- Core: global-stateless, reentrant --------------------------------- */
/* Formats `fmt` and emits each byte via `putc`. Returns the number of
 * characters written, or K_PRINTF_ERR if `putc`/`fmt` is NULL. */
int k_vprintf_cb(k_putc_fn putc, void *userdata, const char *fmt, va_list ap);

/* ---- Explicit-sink API (multiple output targets) ----------------------- */
int k_fprintf (const k_printf_sink_t *sink, const char *fmt, ...);
int k_vfprintf(const k_printf_sink_t *sink, const char *fmt, va_list ap);

/* ---- Classic global API ------------------------------------------------ */
/* Registers the global sink used by k_printf/k_vprintf. A NULL `putc` is
 * rejected (the previous sink is kept). Must be called before k_printf. */
void k_printf_init(k_putc_fn putc, void *userdata);
int  k_printf (const char *fmt, ...);
int  k_vprintf(const char *fmt, va_list ap);

/* ---- Buffer (snprintf) variants ---------------------------------------- */
/* Writes at most `size-1` chars plus a NUL terminator into `buf`. Returns the
 * number of characters that WOULD have been written (ISO snprintf semantics),
 * so a value >= size means the output was truncated. */
int k_snprintf (char *buf, size_t size, const char *fmt, ...);
int k_vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);

#ifdef __cplusplus
}
#endif

#endif /* K_PRINTF_H */
