# k_printf (Türkçe özet)

> Bu, İngilizce ana [README](../README.md)'nin kısa bir özetidir ve **onun
> gerisinde kalabilir**. Kaynak-doğruluk belgesi ana README'dir.

`k_printf`, MSP430 gibi küçük gömülü sistemler için **hafif, freestanding bir
printf** kütüphanesidir. `malloc` yok, libc `printf` yok, format tamponu
gerektirmez — çıktı, verdiğiniz bir callback üzerinden bayt bayt gider.

## ✨ Özellikler

- Belirteçler: `d i u x X o b B c s p %` ve `%%`
- **`long` desteği** (`%ld %lu %lx …`) — MSP430'da `int` yalnızca 16-bit olduğu
  için 32-bit değerler için şart
- Alan **genişliği**, **hassasiyet** ve bayraklar (`-` `+` boşluk `0` `#`), `*`
- Yazılan karakter sayısını döndürür (gerçek `printf` gibi)
- `k_snprintf` / `k_vsnprintf` ile tampona yazma
- Çoklu çıktı hedefi (sink + `userdata`)
- Global durumsuz, yeniden-girilebilir çekirdek (`k_vprintf_cb`)
- Mesaj bütünlüğü için geçersiz kılınabilir `k_printf_lock()/unlock()`
  kancaları (varsayılan: no-op)
- Kod boyutunu kısmak için belirteç bazında derleme anahtarları
- `snprintf`'e karşı diferansiyel test + fuzz (ASan/UBSan); msp430-gcc ile
  çapraz derleme

## 🚀 Hızlı başlangıç

```c
#include <msp430.h>
#include "k_printf.h"

/* v2.0 callback imzası: (char, void *userdata) */
static void uart_putc(char c, void *userdata) {
    (void)userdata;
    while (!(IFG2 & UCA0TXIFG)) { }
    UCA0TXBUF = (unsigned char)c;
}

int main(void) {
    WDTCTL = WDTPW | WDTHOLD;
    k_printf_init(uart_putc, NULL);
    k_printf("Deger: %d (hex %#x)\n", 42, 42);   // Deger: 42 (hex 0x2a)
    k_printf("Tick: %lu\n", 1000000UL);          // %l gerekli — 32-bit
}
```

## ⚠️ Önemli değişiklikler (1.x → 2.0)

- `putc` callback imzası artık `(char, void*)` — `k_printf_init(f, NULL)`.
- Düz `%x` artık `0x` **önekini basmaz**; önek için `%#x` kullanın.
- `%%` artık tek `%` basar.
- Dönüş türü `void` yerine `int` (yazılan karakter sayısı).

## 🛠️ Derleme

```bash
make lib        # libk_printf.a (msp430-gcc)
make example    # example.elf + example_ringbuf.elf
make test       # host testleri (ASan/UBSan)
make fuzz       # snprintf'e karşı diferansiyel fuzz (clang libFuzzer)
```

## 🧪 Sınırlamalar

- `l` olmadan 16-bit aralık: `%d` ±32767, `%u` 0–65535, `%x` en çok 4 hane.
- Kayan nokta (`%f` vb.) ve `%n` yok.
- Bilinmeyen belirteç harfi harfine yankılanır ve argüman tüketmez.
- Çekirdek yeniden-girilebilir; ancak paylaşılan aygıta bayt-bayt çıktı
  varsayılan olarak **atomik değildir** (ISR + main aynı anda yazarsa baytlar
  iç içe geçebilir). Çözüm: kesme güdümlü TX halka tamponu + lock kancaları —
  bkz. [examples/uart_ringbuf.c](../examples/uart_ringbuf.c).

Ayrıntılar ve tam belirteç tablosu için ana [README](../README.md)'ye bakın.

## 📜 Lisans

MIT © [KaanErgun](https://github.com/KaanErgun)
