/*
 * MSP430 usage example for k_printf v2.0.
 *
 * The putc callback signature changed in v2.0: it now takes a userdata
 * pointer, `void uart_putc(char c, void *userdata)`. Pass NULL as userdata to
 * k_printf_init if you don't need it.
 */
#include <msp430.h>
#include "k_printf.h"

/* Write one byte to the USCI_A0 UART (blocking until TX buffer is free). */
static void uart_putc(char c, void *userdata) {
    (void)userdata;
    while (!(IFG2 & UCA0TXIFG)) { /* wait */ }
    UCA0TXBUF = (unsigned char)c;
}

int main(void) {
    WDTCTL = WDTPW | WDTHOLD;   /* stop the watchdog timer */
    /* ... clock + USCI_A0 UART init goes here ... */

    k_printf_init(uart_putc, NULL);

    k_printf("MSP430 hazir!\n");
    k_printf("Sayi: %d, Hex: %#x, Metin: %s\n", -123, 0xABCD, "k_printf");

    /* long is required for 32-bit values on MSP430 (int is only 16-bit) */
    k_printf("Tick: %lu, Register: %#010lX\n", 1000000UL, 0xDEADBEEFUL);

    /* width, zero-fill, left-justify, binary */
    k_printf("Port: %08b, Tablo: [%-8s][%5d]\n", 0xA5, "sol", 42);

    while (1) { /* idle */ }
}
