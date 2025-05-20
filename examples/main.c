#include "k_printf.h"

// MSP430 UART karakter yazım fonksiyonu örneği
void uart_putc(char c) {
    while (!(IFG2 & UCA0TXIFG));
    UCA0TXBUF = c;
}

int main(void) {
    WDTCTL = WDTPW | WDTHOLD;   // Watchdog Timer kapalı
    // UART init buraya

    k_printf_init(uart_putc);
    k_printf("MSP430 hazır!\n");
    k_printf("Sayı: %d, Hex: %x, Metin: %s\n", -123, 0xABCD, "k_printf");

    while (1);
}