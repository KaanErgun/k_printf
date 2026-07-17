/*
 * kp_gold.c - golden-model harness for the k_printf_hdl differential tests.
 *
 * It links the real C library (src/k_printf.c) and, for each stimulus row in
 * vectors.txt, calls k_snprintf through the GENERATED per-message dispatch
 * (hdl/gen/kp_gold.inc, which #includes the SAME messages.h the hardware ROM was
 * built from). The bytes it prints are therefore the C library's own output -
 * the single oracle the SV and VHDL cores are both checked against.
 *
 * Usage:  kp_gold vectors.txt > expected.txt
 *   vectors.txt line:  "<msg_id> <nargs> <a0> <a1> ..."   (args are decimal u32)
 *   expected.txt line: "<len> <b0> <b1> ..."              (output bytes, hex)
 *
 * This is the plan's robust "C shim" oracle: no FFI vararg fragility - the C
 * compiler resolves each message's argument types statically via the dispatch.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include "k_printf.h"

/* pull in messages.h so the dispatch's format strings are the real ones */
#include "kp_gold.inc"

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s vectors.txt\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror("open vectors"); return 2; }

    char line[512];
    while (fgets(line, sizeof line, f)) {
        int msg_id = 0, nargs = 0, pos = 0, consumed = 0;
        if (sscanf(line, "%d %d%n", &msg_id, &nargs, &pos) < 2) continue;
        uint32_t a[16];
        for (int i = 0; i < nargs && i < 16; i++) {
            unsigned long v = 0;
            if (sscanf(line + pos, "%lx%n", &v, &consumed) < 1) { v = 0; consumed = 0; }
            a[i] = (uint32_t)v;      /* args are 8-nibble hex */
            pos += consumed;
        }
        char buf[512];
        int n = kp_gold(msg_id, a, buf, sizeof buf);
        if (n < 0) { printf("-1\n"); continue; }
        /* k_snprintf returns the would-be length (ISO); clamp to what fit */
        int emitted = (n < (int)sizeof buf - 1) ? n : (int)sizeof buf - 1;
        printf("%d", emitted);
        for (int i = 0; i < emitted; i++)
            printf(" %02x", (unsigned char)buf[i]);
        printf("\n");
    }
    fclose(f);
    return 0;
}
