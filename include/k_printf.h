#ifndef K_PRINTF_H
#define K_PRINTF_H

#include <stdarg.h>

void k_printf_init(void (*putc_func)(char));
void k_printf(const char *fmt, ...);

#endif