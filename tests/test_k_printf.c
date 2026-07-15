/*
 * Host-side test harness for k_printf.
 *
 * Two kinds of checks:
 *   CHECK_REF(...)  - run k_printf and the platform snprintf on the SAME format
 *                     and args, assert byte-for-byte equality. Only valid for
 *                     the specifiers both implement identically.
 *   CHECK(exp, ...) - run k_printf and compare against a hand-written expected
 *                     string (for %b, trailing %, NULL %s, and other cases
 *                     snprintf can't or won't reproduce).
 *
 * NOTE on 16 vs 32-bit: host `int` is 32-bit but MSP430 `int` is 16-bit. The
 * INT_MIN negation path (bug 2.1) is exercised here with the *host* INT_MIN;
 * the 16-bit behaviour must be validated separately on an MSP430 simulator.
 * See README "Testing".
 *
 * Build (see Makefile `test` target):
 *   cc -std=c11 -Wall -Wextra -Werror -Iinclude -fsanitize=address,undefined \
 *      src/k_printf.c tests/test_k_printf.c -o build/test && ./build/test
 */
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>
#include "k_printf.h"

static char out[2048];
static size_t n;
static int failures;
static int checks;

static void tputc(char c, void *ud) {
    (void)ud;
    if (n < sizeof out - 1) out[n++] = c;
}

static void run(const char *label, const char *got, const char *exp) {
    checks++;
    if (strcmp(got, exp) != 0) {
        failures++;
        printf("FAIL %s\n   got: \"%s\"\n   exp: \"%s\"\n", label, got, exp);
    }
}

/* Compare k_printf against snprintf for the identical (fmt, args). */
#define CHECK_REF(...) do {                                   \
    char ref[2048];                                           \
    n = 0; k_printf(__VA_ARGS__); out[n] = '\0';              \
    snprintf(ref, sizeof ref, __VA_ARGS__);                   \
    run("k_printf(" #__VA_ARGS__ ")", out, ref);              \
} while (0)

/* Compare k_printf against a literal expected string. */
#define CHECK(exp, ...) do {                                  \
    n = 0; k_printf(__VA_ARGS__); out[n] = '\0';              \
    run("k_printf(" #__VA_ARGS__ ")", out, exp);              \
} while (0)

int main(void) {
    k_printf_init(tputc, NULL);

    /* ---- Regression tests for the v1 bugs ---- */

    /* 2.1 INT_MIN negation (host INT_MIN; 32-bit path) */
    CHECK_REF("%d", INT_MIN);
    CHECK_REF("%d", -2147483647 - 1);
    CHECK_REF("%d", -1);
    CHECK_REF("%d", 0);
    CHECK_REF("%ld", LONG_MIN);

    /* 2.2 lone trailing '%' must not read past the NUL */
    CHECK("", "%");
    CHECK("abc", "abc%");
    CHECK("Battery 100", "Battery 100%");

    /* 2.3 %% -> a single percent */
    CHECK("100%", "100%%");
    CHECK_REF("50%% duty");
    CHECK("%d literal", "%%d literal");

    /* 2.4 NULL passed to %s */
    CHECK("(null)", "%s", (char *)NULL);
    CHECK("[(null)]", "[%s]", (char *)NULL);

    /* 2.5 unknown specifier echoes and does NOT consume the vararg */
    CHECK("%z=7", "%z=%d", 7);
    CHECK("%q", "%q");

    /* 2.6 NULL sink -> K_PRINTF_ERR (does not crash) */
    {
        k_printf_sink_t bad = { NULL, NULL };
        run("null-sink returns err",
            k_fprintf(&bad, "x") == K_PRINTF_ERR ? "err" : "ok", "err");
    }

    /* ---- Core specifiers vs snprintf ---- */
    CHECK_REF("%d %u %c %s", -42, 42u, 'A', "hi");
    CHECK_REF("%x %X %o", 0xABCu, 0xABCu, 64u);
    CHECK_REF("%u", UINT_MAX);
    CHECK_REF("%d", INT_MAX);
    CHECK_REF("%x", 0xFFFFFFFFu);
    CHECK_REF("%i", -12345);

    /* ---- long support (bug 3.1) ---- */
    CHECK_REF("%ld", 1000000L);
    CHECK_REF("%lu", 4000000000UL);
    CHECK_REF("%lx", 0xDEADBEEFUL);
    CHECK_REF("%lX", 0xDEADBEEFUL);
    CHECK_REF("%#010lx", 0xABCDUL);

    /* ---- width / precision / flags (bug 3.2) ---- */
    CHECK_REF("[%5d]", 42);
    CHECK_REF("[%-5d]", 42);
    CHECK_REF("[%05d]", 42);
    CHECK_REF("[%+d]", 42);
    CHECK_REF("[% d]", 42);
    CHECK_REF("[%+05d]", 42);
    CHECK_REF("[%8.3d]", 5);
    CHECK_REF("[%-8.3d]", 5);
    CHECK_REF("[%05.3d]", 42);
    CHECK_REF("[%.0d]", 0);
    CHECK_REF("[%3.0d]", 0);
    CHECK_REF("[%*d]", 6, 42);
    CHECK_REF("[%-*.*d]", 8, 3, 7);

    /* ---- string precision / width ---- */
    CHECK_REF("[%.5s]", "hello world");
    CHECK_REF("[%10.5s]", "hello world");
    CHECK_REF("[%-10.5s]", "hi");

    /* ---- hex prefix behaviour (bug 3.4: plain %x has NO prefix) ---- */
    CHECK("2a", "%x", 42u);
    CHECK("0x2a", "%#x", 42u);
    CHECK_REF("%#x", 255u);
    CHECK_REF("%#08x", 255u);
    CHECK("0", "%#x", 0u);          /* # suppressed for zero */

    /* ---- char width ---- */
    CHECK_REF("[%5c]", 'A');
    CHECK_REF("[%-5c]", 'A');

    /* ---- octal alternate form ---- */
    CHECK_REF("%#o", 64u);
    CHECK_REF("%#o", 0u);

    /* ---- binary (%b): no snprintf oracle, use literals ---- */
    CHECK("10100101", "%b", 0xA5u);
    CHECK("00001111", "%08b", 0x0Fu);
    CHECK("0b1111", "%#b", 0x0Fu);
    CHECK("0", "%b", 0u);
    CHECK("11111111111111111111111111111111", "%lb", 0xFFFFFFFFUL);

    /* ---- return value = chars written ---- */
    run("return value counts chars",
        k_printf("hello") == 5 ? "5" : "?", "5");

    /* ---- k_snprintf: fits, truncation, size 0, ISO return ---- */
    {
        char b[16];
        int r = k_snprintf(b, sizeof b, "%d-%s", 42, "ok");
        run("snprintf fits", b, "42-ok");
        run("snprintf return", r == 5 ? "5" : "?", "5");

        char t[5];
        int r2 = k_snprintf(t, sizeof t, "%d", 123456);  /* needs 6, buf holds 4+NUL */
        run("snprintf truncates", t, "1234");
        run("snprintf ISO return", r2 == 6 ? "6" : "?", "6");

        /* size 0 must not write and must not crash */
        int r3 = k_snprintf(NULL, 0, "%d", 99);
        run("snprintf size 0 return", r3 == 2 ? "2" : "?", "2");
    }

    printf("\n%d checks, %d failure(s)\n", checks, failures);
    return failures ? 1 : 0;
}
