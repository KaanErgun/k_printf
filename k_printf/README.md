# k_printf

`k_printf`, MSP430 gibi gömülü sistemlerde kullanılmak üzere tasarlanmış **hafif ve hızlı bir printf kütüphanesidir**.

## ✨ Özellikler

- `%d`, `%u`, `%x`, `%s`, `%c` destekler
- Hafif ve malloc/format buffer içermez
- Kolay entegre edilebilir
- `putc()` gibi bir karakter yazıcı ile çalışır (örneğin UART)

## 🧪 Örnek Kullanım

```c
k_printf_init(uart_putc);
k_printf("Değer: %d, Metin: %s\n", 42, "Merhaba");
```