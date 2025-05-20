#include "k_printf.h"

static void (*_putc)(char) = 0;

static void print_decimal(int val) {
    char buf[10];
    int i = 0;
    if (val < 0) {
        _putc('-');
        val = -val;
    }
    do {
        buf[i++] = '0' + (val % 10);
        val /= 10;
    } while (val > 0);
    while (i--) _putc(buf[i]);
}

static void print_unsigned(unsigned int val) {
    char buf[10];
    int i = 0;
    do {
        buf[i++] = '0' + (val % 10);
        val /= 10;
    } while (val > 0);
    while (i--) _putc(buf[i]);
}

static void print_hex(unsigned int val) {
    char buf[8];
    int i = 0;
    do {
        int digit = val % 16;
        buf[i++] = digit < 10 ? '0' + digit : 'a' + digit - 10;
        val /= 16;
    } while (val > 0);
    _putc('0');
    _putc('x');
    while (i--) _putc(buf[i]);
}

void k_printf_init(void (*putc_func)(char)) {
    _putc = putc_func;
}

void k_printf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);

    while (*fmt) {
        if (*fmt == '%') {
            fmt++;
            switch (*fmt) {
                case 'd':
                    print_decimal(va_arg(args, int));
                    break;
                case 'u':
                    print_unsigned(va_arg(args, unsigned int));
                    break;
                case 'x':
                    print_hex(va_arg(args, unsigned int));
                    break;
                case 'c':
                    _putc(va_arg(args, int));
                    break;
                case 's': {
                    char *s = va_arg(args, char *);
                    while (*s) _putc(*s++);
                    break;
                }
                default:
                    _putc('%');
                    _putc(*fmt);
            }
        } else {
            _putc(*fmt);
        }
        fmt++;
    }

    va_end(args);
}