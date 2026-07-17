/*
 * Compiled by `make test` with EVERY K_PRINTF_ENABLE_* switch set to 0.
 * Verifies the documented opt-out contract: a disabled specifier is echoed
 * literally and does NOT consume a vararg, so the argument stream stays
 * aligned for the remaining conversions (the plan's bug class 2.5/3.1).
 */
#include <stdio.h>
#include <string.h>
#include "k_printf.h"

static char out[256];
static size_t n;
static int failures, checks;

static void tputc(char c, void *ud) {
    (void)ud;
    if (n < sizeof out - 1) out[n++] = c;
}

#define CHECK(exp, ...) do {                                          \
    checks++; n = 0; k_printf(__VA_ARGS__); out[n] = '\0';            \
    if (strcmp(out, exp) != 0) {                                      \
        failures++;                                                   \
        printf("FAIL k_printf(%s)\n   got: \"%s\"\n   exp: \"%s\"\n", \
               #__VA_ARGS__, out, exp);                               \
    }                                                                 \
} while (0)

int main(void) {
    k_printf_init(tputc, NULL);

    /* the d/i/u/c/s/%% core is always built */
    CHECK("a -5 12 X hi %", "a %d %u %c %s %%", -5, 12u, 'X', "hi");

    /* disabled groups echo literally and must not eat the next vararg */
    CHECK("[%x][7]",  "[%x][%d]", 7);
    CHECK("[%X][7]",  "[%X][%d]", 7);
    CHECK("[%o][7]",  "[%o][%d]", 7);
    CHECK("[%b][7]",  "[%b][%d]", 7);
    CHECK("[%p][7]",  "[%p][%d]", 7);
    CHECK("[%ld][7]", "[%ld][%d]", 7);
    CHECK("[%lu][7]", "[%lu][%d]", 7);
    CHECK("[%lx][7]", "[%lx][%d]", 7);

    printf("%d opt-out checks, %d failure(s)\n", checks, failures);
    return failures ? 1 : 0;
}
