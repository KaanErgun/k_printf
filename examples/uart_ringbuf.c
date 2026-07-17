/*
 * Interrupt-driven TX ring buffer example for k_printf v2.0 (msp430g2553).
 *
 * examples/main.c blocks on TXIFG inside putc: simple, but k_printf then
 * spends ~1 ms per byte at 9600 baud, and messages written from main and an
 * ISR can interleave byte-by-byte. This example instead:
 *
 *   - enqueues each byte into a ring buffer, so k_printf returns as soon as
 *     the message is queued (non-blocking unless the ring is full),
 *   - lets the USCI_A0 TX interrupt drain the ring in the background,
 *   - overrides the weak k_printf_lock()/k_printf_unlock() hooks so a whole
 *     k_printf() message is queued atomically -> no interleaving between
 *     main-context and ISR-context messages. Masking interrupts only around
 *     ENQUEUEING is cheap; masking them around a blocking-putc printf would
 *     stall interrupts for tens of milliseconds at UART speed.
 *
 * Sizing rule: make TX_BUF_SIZE (a power of two) at least as large as your
 * longest message burst, or producers will spin waiting for the ISR.
 */
#include <msp430.h>
#include "k_printf.h"

/* Legacy mspgcc (Debian/Ubuntu gcc-msp430, __MSPGCC__) has no
 * __get_SR_register(); its SR-read intrinsic is __read_status_register(). */
#if defined(__MSPGCC__) && !defined(__get_SR_register)
#define __get_SR_register() __read_status_register()
#endif

#define TX_BUF_SIZE 128u                 /* must be a power of two */
#define TX_MASK     (TX_BUF_SIZE - 1u)

static volatile unsigned char tx_buf[TX_BUF_SIZE];
static volatile unsigned int  tx_head;   /* next free slot (producers write) */
static volatile unsigned int  tx_tail;   /* next byte to send (ISR reads)    */

/* ---- k_printf sink: enqueue, never touch the UART directly -------------- */
static void uart_putc_ring(char c, void *userdata) {
    (void)userdata;
    unsigned int next;

    /* `next` is recomputed each iteration: during the interrupt window below
     * a nested k_printf (from an ISR) may advance tx_head, and a stale value
     * would snap the head backwards and corrupt the ring. */
    while ((next = (tx_head + 1u) & TX_MASK) == tx_tail) {
        /* Ring full. If interrupts are globally masked (inside
         * k_printf_lock(), or when called from an ISR), the TX ISR could
         * never drain the ring: open a one-instruction interrupt window.
         * Note this makes a full ring the one spot where lock atomicity can
         * yield - size TX_BUF_SIZE so it doesn't happen in normal operation. */
        if (!(__get_SR_register() & GIE)) {
            __enable_interrupt();
            __no_operation();
            __disable_interrupt();
        }
    }

    tx_buf[tx_head] = (unsigned char)c;
    tx_head = next;
    IE2 |= UCA0TXIE;                     /* (re)arm the TX interrupt */
}

/* ---- Whole-message atomicity via the weak lock hooks -------------------- */
/* k_printf()/k_vprintf() call these around each whole formatting run.
 * Nesting-safe: a nested k_printf (an ISR logging during the full-ring
 * interrupt window above) must not clobber the outer saved SR, or the outer
 * unlock would restore the ISR's GIE=0 and leave interrupts off for good.
 * Only the outermost lock saves SR; only the outermost unlock restores it. */
static unsigned int lock_sr;
static volatile unsigned char lock_depth;

void k_printf_lock(void) {
    unsigned int sr = __get_SR_register();
    __disable_interrupt();
    if (lock_depth++ == 0u) lock_sr = sr;
}

void k_printf_unlock(void) {
    if (--lock_depth == 0u && (lock_sr & GIE)) __enable_interrupt();
}

/* ---- TX interrupt: feed the UART until the ring is empty ---------------- */
__attribute__((interrupt(USCIAB0TX_VECTOR)))
void usci0_tx_isr(void) {
    if (tx_tail == tx_head) {
        IE2 &= ~UCA0TXIE;                /* nothing left: silence the IRQ */
    } else {
        UCA0TXBUF = tx_buf[tx_tail];     /* clears UCA0TXIFG */
        tx_tail = (tx_tail + 1u) & TX_MASK;
    }
}

int main(void) {
    WDTCTL = WDTPW | WDTHOLD;            /* stop the watchdog timer */

    /* 1 MHz DCO; USCI_A0 UART @ 9600 baud on P1.1 (RXD) / P1.2 (TXD) */
    BCSCTL1 = CALBC1_1MHZ;
    DCOCTL  = CALDCO_1MHZ;
    P1SEL  |= BIT1 | BIT2;
    P1SEL2 |= BIT1 | BIT2;
    UCA0CTL1 |= UCSSEL_2;                /* clock from SMCLK */
    UCA0BR0   = 104;                     /* 1 MHz / 9600 */
    UCA0BR1   = 0;
    UCA0MCTL  = UCBRS0;
    UCA0CTL1 &= ~UCSWRST;                /* release USCI for operation */

    k_printf_init(uart_putc_ring, NULL);
    __enable_interrupt();

    k_printf("ring TX hazir: k_printf kuyruga yazar, ISR bosaltir\n");
    k_printf("Tick: %lu, Reg: %#010lX\n", 1000000UL, 0xDEADBEEFUL);

    while (1) {
        /* Main work goes here; k_printf calls above returned as soon as the
         * bytes were queued, while the ISR was already transmitting. */
    }
}
