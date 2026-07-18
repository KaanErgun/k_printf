/**
 * @file k_printf.h
 * @brief Lightweight, freestanding printf for MSP430 and other small MCUs.
 *
 * v2.0 - no malloc, no libc printf, no format buffer required. The core
 * (k_vprintf_cb) is global-stateless and reentrant; output goes through a
 * user-supplied putc callback.
 *
 * MSP430 note: `int`/`unsigned` are 16-bit, `long` is 32-bit. Use the `l`
 * length modifier (%ld/%lu/%lx) to print 32-bit values.
 *
 * Supported syntax: `%[flags][width][.precision][l]specifier` with specifiers
 * `d i u x X o b B c s p %`, flags `- + space 0 #`, and `*` for a runtime
 * width/precision. See README.md for the full table and limitations.
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

/** @name Versioning (SemVer)
 *  @{ */
#define K_PRINTF_VERSION_MAJOR 2
#define K_PRINTF_VERSION_MINOR 2
#define K_PRINTF_VERSION_PATCH 0
#define K_PRINTF_VERSION       (K_PRINTF_VERSION_MAJOR * 10000 + \
                                K_PRINTF_VERSION_MINOR * 100   + \
                                K_PRINTF_VERSION_PATCH)          /* 20200 */
#define K_PRINTF_VERSION_STRING "2.2.0"   /* repo-level (HDL system features);
                                             no C behaviour changes since 2.0.0 */
/** @} */

/** Returned on error (NULL sink / NULL format). */
#define K_PRINTF_ERR (-1)

/**
 * @brief Character-output callback.
 * @param c        The byte to emit.
 * @param userdata Opaque pointer registered with the sink / init (may be NULL).
 *
 * The callback must not return before the byte is accepted (e.g. wait for
 * UART TX ready, or enqueue into a TX ring buffer).
 */
typedef void (*k_putc_fn)(char c, void *userdata);

/** @brief An explicit output target: a callback plus its userdata. */
typedef struct {
    k_putc_fn putc;
    void     *userdata;
} k_printf_sink_t;

/**
 * @brief Reentrant formatting core: no global state.
 *
 * Formats `fmt` and emits each byte via `putc`.
 * @return The number of characters written, or #K_PRINTF_ERR if `putc`/`fmt`
 *         is NULL.
 */
int k_vprintf_cb(k_putc_fn putc, void *userdata, const char *fmt, va_list ap);

/** @name Explicit-sink API (multiple output targets)
 *  @{ */
int k_fprintf (const k_printf_sink_t *sink, const char *fmt, ...);
int k_vfprintf(const k_printf_sink_t *sink, const char *fmt, va_list ap);
/** @} */

/**
 * @brief Registers the global sink used by k_printf/k_vprintf.
 *
 * A NULL `putc` is rejected (the previous sink is kept). Must be called
 * before k_printf; until then k_printf returns #K_PRINTF_ERR.
 */
void k_printf_init(k_putc_fn putc, void *userdata);

/** @brief printf to the global sink. @return Chars written or #K_PRINTF_ERR. */
int  k_printf (const char *fmt, ...);
/** @brief va_list variant of k_printf(). */
int  k_vprintf(const char *fmt, va_list ap);

/** @name Optional critical-section hooks (global-sink path only)
 *
 * k_printf/k_vprintf call k_printf_lock() before formatting and
 * k_printf_unlock() after. The default implementations are no-ops with weak
 * linkage: override them to make whole messages atomic against other
 * contexts (e.g. save interrupt state + disable, then restore). They are NOT
 * called on the explicit-sink or snprintf paths, which have no shared state.
 *  @{ */
void k_printf_lock(void);
void k_printf_unlock(void);
/** @} */

/** @name Buffer (snprintf) variants
 *
 * Write at most `size-1` chars plus a NUL terminator into `buf`. Return the
 * number of characters that WOULD have been written (ISO snprintf semantics),
 * so a value >= size means the output was truncated.
 *  @{ */
int k_snprintf (char *buf, size_t size, const char *fmt, ...);
int k_vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
/** @} */

#ifdef __cplusplus
}
#endif

#endif /* K_PRINTF_H */
