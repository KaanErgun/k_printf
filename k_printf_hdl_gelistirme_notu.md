# k_printf_hdl Geliştirme Notu

> Kapsam: k_printf v2.0.0 C çekirdeğinin (`src/k_printf.c`, 383 satır) **FPGA'da sentezlenebilir, vendor-bağımsız** donanım karşılığının planı — uygulama değil, plan. Hedef ürün: format tanımı + ikili argümanları alıp **biçimlenmiş ASCII bayt akışını** valid/ready el sıkışmasıyla (tipik alıcı: UART TX) üreten RTL çekirdeği; hem **SystemVerilog** hem **VHDL-2008** gerçeklemesi.
> Simülasyon-printf (`$display`, `textio`) hedef değildir — orada katma değer yok; sim tarafı yalnızca doğrulamada rol alır. Asıl değer: CPU'suz saf-RTL tasarımlardan deterministik, insan-okur telemetri/debug akışı.
> Dayanaklar: `src/k_printf.c`, `include/k_printf.h`, `README.md`, `examples/uart_ringbuf.c`, `tests/test_k_printf.c`, `tests/fuzz_k_printf.c`, `tests/test_optout.c`. **Dürüst durum tespiti:** yerel klonda `.github/workflows/` ve `tools/` dizini **henüz yok** — CI iskeleti ve codegen aracı bu planın önkoşul işidir (Faz 0, Bölüm 6.9), "mevcut CI'a eklenir" varsayımı yapılmaz.
> Hedef aileler: **iCE40** (HX1K/UP5K — LUT4, EBR=4 kbit, **LUTRAM yok**), **ECP5**, **Artix-7**. LUT tahminleri LUT4 eşdeğeridir (Artix LUT6 için ×0.6–0.7), ±%40 bantta okunur ve Faz 1'de gerçek sentezle kalibre edilir.
>
> **⚠️ CI→yerel uyarlaması (proje kuralı):** Bu doküman çok-ajanlı bir planlama turundan çıktı ve metnin çeşitli yerlerinde "CI'da bloklayıcı", "PR'da koşar", "hdl-* işi", "nightly" gibi ifadeler geçer. **Bu projede GitHub CI kullanılmaz** — tüm bu ifadeler §6.9'daki **yerel `make -C hdl` hedefleriyle** karşılanır ("bloklayıcı" = commit öncesi geçmesi zorunlu; "nightly" = periyodik elle koşu). Doğrulama, C tarafındaki `make test`/`make fuzz-standalone` ile simetrik biçimde yereldedir. Referans gerçekleme bu oturumda başlatıldı; güncel durum için §8 sonundaki "Uygulama durumu" notuna bakın.

## 1. Özet

v2.0 C kütüphanesi donanım portu için ideal bir referans: `k_vprintf_cb` global durumsuz, `k_snprintf` bayt-bayt deterministik ve `tests/` altında `snprintf`'e karşı çalışan bir diferansiyel test + fuzz altyapısı hazır. Plan bu zinciri bir halka uzatır: **oracle zinciri `snprintf → C k_printf → k_printf_hdl`** — C kütüphanesi RTL'in altın modeli olur, iki HDL gerçeklemesi hem ona hem birbirine karşı bayt-bayt koşulur.

Ana kararların özeti:

- **Format derleme zamanında, argüman çalışma zamanında.** Format stringleri host'ta bir kod üreteci (`tools/k_fmtgen.py`) ile **µop (mikro-komut) dizilerine** derlenip ROM'a gömülür; çalışma anında istemci yalnızca `{msg_id, argümanlar}` verir. Runtime ASCII parser tümüyle atılmaz: opsiyonel, generic-kapılı bir **ön-uç** olarak Faz 3'te gelir (dinamik format + C sözleşmelerinin — bilinmeyen belirteç yankısı, sondaki `%` — donanımda birebir var olabilmesi için).
- **Motor yalnızca µop tüketir; ROM ön-ucu ve runtime parser birer ön-uçtur.** Bu, C'deki `k_vprintf_cb` çekirdek + sarmalayıcılar ayrışmasının RTL izdüşümüdür. µop ISA'sı Faz 0'da sürüm alanıyla dondurulur; **hata davranışı (geçersiz `msg_id`, bozuk/rezerv opcode) ve reset sözleşmesi de ISA ile birlikte Faz 0'da yazılır** (Bölüm 3.9) — tanımsız davranış bırakılmaz, formal görevler ancak böyle kanıt üretebilir.
- **Alan optimize edilir, hız değil:** UART her zaman darboğazdır (115200'de 1 bayt ≈ 86.8 µs; en yavaş dönüşüm ~350 çevrim ≈ 7 µs @48 MHz). Ondalık dönüşüm **seri double-dabble** (tek zaman-paylaşımlı add-3 düzeltici) — bölücü datapath'i hiç kurulmaz. Tüm tabanlar tek kaydırıcı + tek emit motorundan geçer (C'deki tek `fmt_int`'in donanım karşılığı).
- **Bağlayıcı kaynak bütçesi:** MINI ≤ ~300, BASE ≤ ~400, FULL ≤ ~1200 LUT4; CI'da yosys/nextpnr alan regresyonu (bütçe aşımı = kırmızı build) + **konfig başına asgari fmax eşiği** (Bölüm 6.9). Dürüstlük kontrolü: PicoRV32-small (~750–1000 LUT) + firmware'de C k_printf aynı işi görür — **BASE** CPU'dan belirgin küçük kalmazsa çekirdek varlık gerekçesini kaybeder.
- **Kadans: önce SystemVerilog, sonra VHDL portu** (ayrı fazda, cocotb barajıyla zorlanan eşdeğerlik). İki dili baştan kilit adımda yürütmek erken maliyeti ikiler. Yapısal ayna yalnız PR disipliniyle değil, **mekanik port-imza diff'iyle (`hdl-mirror` CI işi)** korunur (Bölüm 5).
- **Doğrulamanın manşeti:** Oracle `k_snprintf` olunca, C fuzzer'ının `snprintf` yüzünden dışlamak zorunda kaldığı bölge (`%b/%B`, `%p`, NULL-`%s`, bilinmeyen-belirteç yankısı) **ilk kez tam diferansiyel test edilebilir** — donanım projesi, C projesinin test edemediğini test eder.
- **Donanım-özgü değer önerisi:** N tetik kaynağı için argümanların **tek saat çevriminde atomik anlık görüntüsü** + mesaj-taneli arbiter — yazılım printf'in hiçbir zaman veremediği garanti. Snapshot-sonrası yeniden-tetikleme penceresinin politikası da tanımlıdır (Bölüm 3.9.4).

---

## 2. Kapsam ve Temel Kararlar

### 2.1 Karar tablosu (gerekçeli)

| Eksen | Karar | Gerekçe |
|---|---|---|
| Mesaj modeli | Format = sentez zamanı (µop ROM), argüman = çalışma zamanı | Runtime parse pahalı; log kullanımının ezici çoğunluğu sabit format; Trice/defmt'in "deferred formatting" fikrinin donanıma taşınmışı |
| Runtime parser | Opsiyonel generic-kapılı ön-uç (`G_EN_RUNTIME_FMT`, Faz 3, ~180 LUT) | Tamamen dışlanırsa bilinmeyen-belirteç yankısı ve sondaki-`%` gibi C sözleşmeleri donanımda hiç var olamaz (bytecode modunda derleme hatasıdırlar); çekirdeğe girmez, ön-uç kalır. Parser modunda `%s` argümanı **tablo-ID** olarak yorumlanır (bellek adresi değil) — Bölüm 4 |
| Ondalık dönüşüm | **Seri double-dabble**, tek zaman-paylaşımlı add-3 düzeltici; `G_DD_PARALLEL` opsiyonu (+~50 LUT, 32 çevrime iner) | Bölücü datapath'i hem büyük hem yavaş; UART matematiği gecikmeyi önemsizleştirir (Bölüm 3.6). MSP430'daki "donanım bölme yok" gerçeğinin RTL ucu: bölme hiç kurulmaz |
| Motor sözleşmesi | µop ISA v1, Faz 0'da **sürüm alanıyla** dondurulur; 1 op-modu + 1 uzatma-kelimesi rezervi; **rezerv/bozuk kodlama davranışı da spec'in parçası** (Bölüm 3.9.2); ROM başlık sürümü RTL beklentisiyle **elaborasyon/çalışma anında doğrulanır** (Bölüm 3.9.3) | ISA değişikliği dört yeri kırar (codegen + iki RTL + TB); rezerv, FULL özellikleri sıkıştırmadan büyümeye izin verir; sürüm assert'i "eski ROM imajı + yeni RTL" sınıfını sessizce çalışmaktan çıkarır |
| Argüman yuvası | 32-bit yuva + µop `size` biti (16/32); arg-slot alanı 3 bit (≤8), `G_ARGC_MAX` varsayılan 4 | `l` karşılığı; yuva hep 32-bit, kesme semantiği `size` bitinden. **Arity'nin tek otoritesi ROM arity tablosudur — mesaj kaydında `argc` alanı yoktur** (Bölüm 3.9.5) |
| **`l`'siz semantik (Faz 0'da dondurulan cümle)** | `l`'siz dönüşüm 32-bit yuvanın **alt 16 bitini** kullanır; `%d/%i` için bit-15'ten işaret uzatılır (MSP430 `int` semantiği). `k_fmtgen` ve test üreteci `l`'siz vakalarda değerleri int16/uint16 aralığına kısıtlar → host'ta 32-bit `int`'le çağrılan altın modelle bayt-bayt eşitlik korunur. **`*` genişlik/hassasiyet argümanları `size` bitinden bağımsız, yuvanın 32 bitinden işaretli okunur** (Bölüm 3.2.1) | Netleştirilmezse altın modelle (host int 32-bit) sistematik uyumsuzluk üretir — C tarafındaki 16/32-bit tuzağının donanım analoğu |
| Genişlik/hassasiyet tavanı | µop'ta 6-bit alanlar, satürasyon **63** (`G_MAX_FIELD`, belgeli C sapması) | C'de INT_MAX'a kadar dolgu anlamlı ama donanımda değil; mevcut fuzzer MAX_WIDTH/MAX_PREC=40 ürettiğinden tavan ≥40 olmalı ki C fuzz korpusu yeniden kullanılabilsin (31'lik tavan korpus paylaşımını kırardı) |
| Doluluk politikası | **Kaynak tipine göre**: donanım tetik kaynağı → DROP + `dropped_cnt` (ops. `"[n dropped]"` işaret mesajı); CPU istemci → STALL (blocking-putc simetrisi). Port başına generic. DROP **mesaj-taneli ya-hep-ya-hiç**tir (Bölüm 6.5) | HW tetik DUT'u durduramaz; CPU zaten bloklamaya alışıktır |
| Hata davranışı | Geçersiz `msg_id` / bozuk µop → mesaj **düşürülür**, sticky `STATUS` biti + `err_cnt`, ops. işaret mesajı; motor asla kilitlenmez (Bölüm 3.9.1–3.9.2) | Register haritası istemcisi keyfi `msg_id` yazabilir; davranış spec'te olmadan `no-deadlock` formal görevi bu vakaları kanıtlayamaz |
| `%s` modeli | Faz 1: ROM string tablosu `{addr,len}` (NULL→`"(null)"` girdisi); Faz 3: uzunluk-önekli satır-içi bayt — **ayrı STR-FIFO yan kanalıyla, mesaj kaydı sabit genişlikte kalır** (Bölüm 3.9.6); genel bellek okuma portu ayrı **adaptör modülü** olarak en sona | Uzunluk basmadan önce bilinirse sağa-yaslı genişlik bedava; NUL'suz-string kilitlenme sınıfı yapısal olarak yok; AXI bağımlılığı çekirdeğe sokulmaz |
| Saat/CDC | Tek saat bölgesi; UART baud'u türetilmiş saat değil **clock-enable** (kesirli N.F akümülatör — MSP430 `UCBRS` modülasyonunun karşılığı) → CDC hiç doğmaz. **Sözleşme cümlesi: tüm tetik ve istemci girişleri çekirdek saat bölgesindedir**; başka bölgeden tetik gerekiyorsa **tetik başına req-ack tutmalı adaptör** (`kp_cdc_trig`, Faz 3 ops.) — çok-bitli arg vektörü çıplak 2FF senkronizerle **taşınamaz** (bit tutarsızlığı). Çift saat gerekirse gray-pointer async FIFO bayt-akışı sınırında; bu senaryoda **iki bölgeye ayrı, senkron-deassert'li reset dağıtımı** zorunlu | Yaygın durumda gerçek CDC yok; icat edilmemeli — ama tetik kaynakları çekirdek dışından geldiği için sınır sözleşmeye yazılmak zorunda |
| Reset | **`rst_i`: senkron, aktif-yüksek, senkron assert+deassert (≥2 çevrim)**; yalnızca **kontrol yoluna** (FSM/FIFO pointer/valid); veri/BCD/kaydırıcı yazmaçları resetsiz; reset sırasında `out_valid=0`, UART hattı idle-1. Mesaj-ortası reset = **flush** sözleşmesi (Bölüm 3.9.4) | Alan + yönlendirme kazancı; sahte start biti yok; adlandırma stil sözlüğünde (Bölüm 5) |
| Repo | **Monorepo, `hdl/` dizini**; ayrılma kriterleri şimdiden yazılı | Oracle bağımlılığı: `src/k_printf.c`'ye dokunan PR, HDL diferansiyel testini **aynı CI koşusunda** kırar; ISA değişikliği tek commit'te atomik |
| Dil kadansı | SV altın kaynak, VHDL-2008 birinci sınıf el portu (ayrı faz); eşdeğerliği makine (ortak cocotb + `hdl-mirror` port-imza diff'i) zorlar | İki bağımsız RTL = sessiz drift; otomatik çeviri = okunmaz kod; kilit adım = erken maliyet ×2 |
| Paketleme | FuseSoC `.core` + saf Makefile, ikisi birden; Verible + VSG lint CI'da bloklayıcı (**araç tedariki Bölüm 6.9'da pinli**) | FuseSoC ekosistem standardı; Makefile araçsız kullanıcıya giriş kapısı |
| Lisans | MIT (C tarafıyla aynı, tek lisanslı repo) | RTL kaynak koddur; CERN-OHL-P kazanımı marjinal, çift-lisans karmaşası maliyetli |
| Kapsam dışı (dürüst Limitations) | `%f/%e/%g`, `%n`, `ll`/64-bit, çalışma-zamanı format değişimi olmadan ROM güncelleme (bitstream ister); reset-anında havadaki UART baytı kesilir (tek çerçeve hatası olabilir — Bölüm 3.9.4) | C sürümüyle simetrik sınırlamalar bölümü |

### 2.2 C v2 ↔ HDL kavram eşlemesi

| k_printf v2 (C) | k_printf_hdl karşılığı |
|---|---|
| `putc` callback + `userdata` | 8-bit valid/ready çıkış akışı (`out_data/valid/ready/last`); `userdata` ≈ `out_dest` sink etiketi |
| putc'un bloklaması | `out_ready=0` → çekirdek stall (tek geri-basınç zinciri) |
| `k_printf(fmt, ...)` çağrısı | mesaj kaydı `{msg_id, arg0..argN}` — FIFO'ya bütün halinde atomik giriş (**arity ROM'dan; kayıtta `argc` alanı yok**, Bölüm 3.9.5) |
| `va_arg` akışı | mesaj içi ARG sözcükleri; desync tasarımda yapısal olarak imkânsız |
| `k_vprintf_cb` (durumsuz çekirdek) | µop tüketen biçimleme motoru (`kp_core`) |
| `k_printf_lock/unlock` | mesaj-taneli arbiter grant (start→done kilidi) — bayt iç-içe geçmesi yapısal olarak yok |
| `k_fprintf` (çoklu sink) | `out_dest` + akış demux'u |
| `k_snprintf` | capture-buffer sink: BRAM'e yaz + `msg_len` sayacı; taşmada C ile aynı: yazmayı kes, saymaya devam |
| `int` dönüş değeri | `msg_len[15:0]` + `done` |
| `K_PRINTF_ENABLE_*` | generic/parameter + `generate` kapıları — kapatılan blok hiç elaborate edilmez (C'deki `#if`+`--gc-sections`'tan daha kesin) |
| ISR'den loglama | donanım tetik noktaları: `trig` + arg vektörü, **1 çevrimde atomik anlık görüntü** |
| snprintf = C'nin oracle'ı | **C k_printf = RTL'in oracle'ı** (zincir: snprintf → k_printf → k_printf_hdl) |

---

## 3. Mimari

### 3.1 Blok diyagramı

```
                              k_printf_hdl cekirdegi
  +--------------------------------------------------------------------------+
  |                                                                          |
HW tetik 0..N-1        +-----------+  msg={msg_id,args}                      |
{trig, args} --------->| snapshot  |   +----------+     +-----------------+  |
 (1 clk atomik)        | + arbiter |-->| MSG FIFO |---->| Sequencer       |  |
CPU (native port /     | (mesaj    |   +----------+     | msg_id -> uop   |  |
 register haritasi) -->|  taneli)  |                    | fetch + gecerlilik  |
                       +-----------+                    | denetimi (3.9.1)|  |
fmt bayt akisi         +--------------+  uop akisi      +--------+--------+  |
(ops., Faz 3) -------->| runtime      |--------------->+         |           |
                       | parser FSM   |                v         v           |
                       +--------------+       +---------------------+        |
                                              | Bicimleme motoru    |<-------+-- uop ROM
                       ARG oku <--------------| (kp_core FSM)       |        |  (k_fmtgen ciktisi,
                                              |  paylasilan kaydirici        |   surum baslikli)
                       STR tablo/ROM <--------|  + double-dabble BCD|<-------+-- LIT ROM
                       STR-FIFO (Faz 3) <-----|  + hex/oct/bin ASCII|        |
                                              |  + ndigits oncelik  |        |
                                              |    kodlayici        |        |
                                              |  + genislik/dolgu   |        |
                                              |    sayaclari (emit) |        |
                                              +----------+----------+        |
                                                         v                   |
                                              +---------------------+        |
                                              | cikis yazmaci       |--------+-> out_data[7:0]
                                              | valid/ready/last/   |           out_valid/out_ready
                                              | dest, msg_len       |           out_last, out_dest
                                              +---------------------+        |
                                              STATUS: err_cnt/dropped_cnt/   |
                                              sticky bitler (3.9)            |
  +--------------------------------------------------------------------------+
   Ornek sink'ler (cekirdek disi): kp_uart_tx (N.F baud akümülatörlü) + TX FIFO,
   capture-BRAM (k_snprintf karsiligi), akis demux (k_fprintf karsiligi)
```

### 3.2 µop ISA taslağı (32-bit sözcük; Faz 0'da dondurulur)

| op (2b) | Ad | Alanlar |
|---|---|---|
| `00` | **LIT** | `rom_addr`, `len[7:0]` → literal baytları LIT-ROM'dan akıt (`%%` ve düz metin derlemede buraya erir) |
| `01` | **FMT** | `base[1:0]` (10/16/8/2), `upper`, `signed`, `size` (16/32), `flags[4:0]` (`0 - + boşluk #`), `width[5:0]`, `prec[5:0]+prec_en`, `w_from_arg`, `p_from_arg`, `arg_slot[2:0]` |
| `10` | **STR** | `mode[1:0]` (`00`=tablo-ID · `01`=satır-içi (Faz 3) · `10`=**CHR** · `11`=rezerv), `flags`, `width[5:0]`, `prec[5:0]+prec_en`, `arg_slot[2:0]` |
| `11` | **EOM** | mesaj sonu → `out_last`, `msg_len` raporu |

ISA başlığında **sürüm alanı** (ROM imajının ilk sözcüğü; doğrulama mekanizması Bölüm 3.9.3); `STR.mode=11` + 1 uzatma-kelimesi rezerv (rezerv kodlamayla karşılaşma davranışı Bölüm 3.9.2 — spec'in parçası, "tanımsız" değil).

**`%c` kodlaması (Faz 0'da ISA ile birlikte dondurulur):** `%c` için ayrı opcode yoktur — 2-bit op uzayı doludur; `%c` = **`STR mode=CHR`**: `arg_slot`'un gösterdiği yuvanın **düşük baytı** tek karakter olarak basılır; `width` ve `-` bayrağı STR'nin mevcut pad yolunu aynen paylaşır (gövde uzunluğu sabit 1). Böylece Faz 1 kapsamındaki `%c`, ISA dondurulmadan kodlanmış olur; ekstra datapath maliyeti ~0.

#### 3.2.1 Runtime `*` kodlaması: ardışık-yuva konvansiyonu (Faz 0'da dondurulur)

C'deki `va_arg` sırası birebir korunur — **ayrı `w_slot/p_slot` alanı yoktur**; `arg_slot[2:0]` dönüşümün **taban indeksidir** ve okuma sırası şudur:

1. `w_from_arg=1` ise **genişlik** `arg_slot`'tan okunur;
2. `p_from_arg=1` ise **hassasiyet** bir sonraki yuvadan okunur;
3. **değer** her zaman son tüketilen yuvayı takip eden yuvadan okunur.

Yani bir dönüşüm en çok **3 ardışık yuva** tüketir (`%*.*d` → w, p, değer). Sonuçları:

- **Arity hesabı:** `k_fmtgen`, `*` argümanlarını arity'ye **dahil eder**; mesajın toplam yuva ihtiyacı `G_ARGC_MAX`'ı aşarsa **üretim anında reddeder** (varsayılan `G_ARGC_MAX=4` ile tek `%*.*X` + 1 ek argüman sığar; `messages_report.md` yuva doluluk envanteri basar, sıkışan projeler generic'i 8'e çıkarır — ISA değişmez, alan 3 bit).
- **`arg-discipline` formal beyanı:** µop başına tüketilen yuva sayısı = `1 + w_from_arg + p_from_arg` (FMT/STR-CHR için; LIT/EOM = 0). Formal özellik bu formülü ROM'daki beyanla karşılaştırır (Bölüm 6.7).
- **Genişlik/hassasiyet argümanının tip yorumu:** `size` biti **yalnız değere** uygulanır; `*` genişlik/hassasiyet argümanları her zaman yuvanın **32 bitinden işaretli** okunur. Negatif genişlik C'deki gibi `-` bayrağı + |w| (63'e satürasyon); **negatif hassasiyet C'deki gibi "hassasiyet yok"** sayılır. Test üreteci, 2.1'deki 16-bit sözleşmesiyle uyum için `*` argümanlarını da int16 aralığında üretir (altın modelle bayt eşitliği aralık içinde tanımlı).

### 3.3 C semantiğinin satır düzeyinde taşınması

Aşağıdaki davranışlar C kaynağından birebir RTL sözleşmesine girer (her biri yönlendirilmiş test vakasıdır):

- **Üç dallı LAYOUT emit dizisi:** sol-yaslı `[SIGN][PREFIX][ZEROS] DIGITS [PAD_SPACE]` · sıfır-dolgu `[SIGN][PREFIX][PAD_ZERO+ZEROS] DIGITS` (yalnız prec yokken) · sağ-yaslı `[PAD_SPACE][SIGN][PREFIX][ZEROS] DIGITS`. Her emit adımı `out_ready` ile kapılıdır.
- **`0` bayrağı, precision varken yok sayılır** (C kuralı birebir).
- **`prec=0` ve değer `0` → hiç basamak basılmaz.**
- **`%#o` istisnası** (öncü `0`, C 7.21.6.1 kuralı dahil).
- **INT_MIN-güvenli negasyon:** işaretli değer, `0 − (unsigned)` çıkarmasıyla büyüklüğe çevrilir — C'deki UB-güvenli desenin donanım eşi (donanımda UB yok, ama genişlik sözleşmesi aynı kalır).
- **Bilinmeyen/kapalı belirteç:** parser modunda harfi harfine yankılanır ve **argüman tüketmez** (ARG pop yok → desync yok); bytecode modunda `k_fmtgen` üretimde reddeder (C'den daha güvenli).
- **Sondaki tek `%` düşürülür** (parser modunda).
- **`tmp[]` ters çevirme tamponu yok:** double-dabble sonunda BCD yazmacı, hex/okt/bin'de değer yazmacı zaten MSB-first okunur; **öncelik kodlayıcı** ilk sıfır-olmayan basamağı 1 çevrimde bulur → `ndigits` bedavaya çıkar (sağa-yaslı dolgu hesabı için gerekli).

### 3.4 Alan hileleri (bütçeyi tutturan kararlar)

1. **Tek zaman-paylaşımlı datapath:** `%d %u %x %X %o %b %B %p` hepsi aynı kaydırıcı + aynı emit motorundan geçer; belirteç başına ayrı donanım yasak.
2. **Seri double-dabble, tek add-3 düzeltici:** paralel düzeltici zinciri yerine bit başına haneleri sırayla düzelten tek düzeltici (~350 çevrim/32-bit — UART yanında ölçülemez).
3. **Bölücü yok, çarpan yok:** ondalık = double-dabble; parser'da genişlik biriktirme `w<<3 + w<<1 + d` (iki toplayıcı). DSP kullanımı 0 → iCE40 HX'te de aynı kod.
4. **Sadece kontrol yoluna reset** (Bölüm 2.1, ayrıntı 3.9.4).
5. **iCE40 gerçeği — LUTRAM yok:** arg FIFO gibi küçük bellekler FF yerine EBR'ye itilir (HX1K'da 16, UP5K'da 30 EBR — bol); ECP5/Artix'te aynı kod dağıtık RAM'e iner (çıkarım şablonu vendor-nötr).
6. **Literal koşular ROM'da ham bayt** — sıkıştırma decoder'ı ROM bitinden pahalı.
7. **Skid-buffer yok:** çekirdek zaten stall edebildiği için çıkışta tek yazmaç yeter.

### 3.5 Bağlayıcı kaynak bütçesi

Blok-bazlı türetilmiş, **bağlayıcı** tablolar (CI alan regresyonunun eşiği; sentez sapması >%25 → bu bölümdeki hileler listesine dönülür). **Konfig tanımları faz teslimatlarıyla birebir hizalıdır** — Faz 1'in teslim ettiği şeyle CI'ın ölçtüğü şey aynıdır:

| Konfig | Kapsam | Bağlayıcı olduğu faz | LUT4 | FF | EBR/BRAM | Sığma |
|---|---|---|---|---|---|---|
| **MINI** | ROM ön-uç; `%x %X %c %%` + ROM-`%s`; 16-bit değer yolu; **genişlik/dolgu yok, ondalık yok**; tek istemci; UART sink | **Faz 1** (madde 12) | **180–300** | ~120 | 2 EBR | iCE40 HX1K'da ~%14–23; Artix'te ~120–200 LUT6 |
| **BASE** | MINI + `%d %i %u` (seri DD, 16-bit) + genişlik+`0`-dolgu | **Faz 2 ara teslimi** (madde 15 sonu) | **300–420** | ~170 | 2–3 EBR | HX1K'da ~%25–33 (kullanıcıya yer kalır) |
| **FULL** | 32-bit, tüm belirteçler + bayraklar + `.prec` + `*`, runtime parser, satır-içi `%s`, 2–4 istemcili arbiter, UART + capture sink | **Faz 3** | **900–1300** | ~380–450 | 4–6 EBR | UP5K'da ~%20–25; HX1K = MINI/BASE-only |

Blok kırılımı (MINI/BASE/FULL, LUT): sequencer 50/60/80 · runtime parser —/—/180 · arg FIFO 25/25/30 · paylaşılan kaydırıcı+negasyon 25/35/55 · double-dabble —/35/55 · hex/oct/bin 15/15/18 · emit/pad 20/35/90 · `%s` motoru —/—/60 · çıkış yazmacı 15/15/15 · TX FIFO 30/30/30 · UART TX 40/40/40 · arbiter —/—/110 · capture sink —/—/40 (+%20–30 glue marjı). **Dürüstlük eşiği:** BASE ≤ ~400 LUT4 ve FULL ≤ ~1200 LUT4 — PicoRV32-small (~750–1000 LUT) + C k_printf'ten belirgin küçük kalınmazsa tasarım gerekçesini kaybeder (kıyas noktası BASE'dir: "kullanılabilir printf" ondalık+genişlik içerir); bu eşikler CI'da kırmızı-build sınırıdır. `hdl-synth` regresyonu her fazda **o faza kadar teslim edilmiş konfiglere karşı** koşar (Faz 1'de yalnız MINI bağlayıcı; BASE bütçesi Faz 2'de double-dabble + pad motoru inince bağlanır — Faz 1 CI'ı var olmayan bloğu ölçmez). Tüm sayılar Faz 0 sentez spike'ı + Faz 1 kalibrasyonuna kadar hipotezdir.

### 3.6 Gecikme bütçesi

| Dönüşüm | Çevrim | @48 MHz | @24 MHz (UP5K) | Kıyas: 1 UART baytı |
|---|---|---|---|---|
| 16-bit ondalık (seri DD) | ~100 | 2.1 µs | 4.2 µs | 86.8 µs @115200 |
| 32-bit ondalık (seri DD) | ~350 | 7.3 µs | 14.6 µs | " |
| 32-bit hex | ~10 | 0.2 µs | 0.4 µs | " |

En kötü dönüşüm bile bayt süresinin ~%17'si (UP5K@115200) → **UART her zaman darboğaz**, seri datapath hiçbir konfigde throughput kaybettirmez. Çıkış tepe hızı 1 bayt/çevrim. Bu tablonun varsaydığı saat frekansları (48/24 MHz) keyfî değildir — **Bölüm 6.9'daki asgari fmax kabul kriterleriyle aynıdır**; fmax eşiğin altına düşerse CI kırmızıdır, tablo sessizce geçersizleşemez.

### 3.7 Sistem tarafı: tetikler, arbiter, entegrasyon yüzeyleri

- **Donanım tetik noktaları:** N adet `{trig, args}` girişi; tetikte argümanlar **tek çevrimde gölge yazmaca atomik kilitlenir**, ardından round-robin arbiter **mesaj taneciliğinde** söz verir. Bu, yazılım printf'in asla veremediği garanti — projenin donanım-özgü satış cümlesi. **Saat sözleşmesi:** tüm `{trig, args}` girişleri çekirdek saat bölgesinde örneklenir (2.1); başka bölgeden kaynak, `kp_cdc_trig` req-ack adaptörü (Faz 3, ops.) arkasından bağlanır — çıplak 2FF ile çok-bitli arg taşınmaz. **Snapshot-sonrası yeniden-tetikleme penceresi** (grant beklerken aynı kaynağın tekrar ateşlemesi) Bölüm 3.9.4'te politikaya bağlanmıştır — tanımsız değildir.
- **Katmanlı istemci yüzeyleri (hepsi aynı native porta iner):** (0) native valid/ready port — `msg_valid/ready`, `msg_id`, düz `args` vektörü; sözleşme: el sıkışma çevriminde mesaj **kopyalanır**, istemci argleri hemen değiştirebilir; **`argc` alanı yoktur** — arity ROM'dan okunur (3.9.5). (1) register haritası (Faz 3): `STATUS/CTRL/ARG0..3` + **write-to-fire `SEND`** (msg_id yazımı atomik tetik — ayrı START biti yarış penceresi açardı); `STATUS`: `dropped_cnt`, `err_cnt` + sticky `BAD_MSG / BAD_UOP / ISA_MISMATCH / OVF` bitleri (yazınca-temizlenir); üstüne ~50 satırlık AXI-Lite ve Wishbone adaptörleri. (2) AXIS paket ön yüzü (Faz 3): arity ROM'dan bilinir, `tlast` uyumsuzluğu hata sayacı + yeniden-senkron.
- **`k_fmtgen` C köprüsü:** üretilen `k_printf_hw.h` ile softcore, format stringini hiç taşımadan donanım printf'i çağırır — **flash'tan format stringlerini tamamen silen printf**, footprint felsefesinin mantıksal ucu.

### 3.8 `examples/uart_ringbuf.c` ↔ RTL birebir eşleme (README-HDL geçiş bölümünün iskeleti)

| uart_ringbuf.c (C/MSP430) | RTL karşılığı |
|---|---|
| `tx_buf[128]` halka tamponu (2'nin kuvveti) | TX FIFO (EBR/BRAM, `G_TX_FIFO_DEPTH`, 2'nin kuvveti) |
| `uart_putc_ring` dolulukta bekler | FIFO dolu → `ready=0` → çekirdek stall (aynı bloklama noktası) |
| USCI TX ISR tamponu boşaltır | UART TX FSM'i FIFO'yu bağımsız tüketir |
| `k_printf_lock/unlock` mesaj atomikliği | Arbiter mesaj-granüllü grant — bayt iç-içe geçmesi yapısal olarak imkânsız |
| "TX_BUF_SIZE'ı en uzun mesaj patlamana göre boyutla" | Aynı kural: `G_TX_FIFO_DEPTH ≥ en uzun mesaj patlaması`; yetmezse stall (hata değil, geri-basınç) |
| Dolu-halka + GIE-kapalı kilitlenme penceresi | **Sınıfça yok:** tüketici (UART FSM) üreticiden bağımsız donanım |
| MSP430 `UCBRS` baud modülasyonu | Kesirli N.F baud akümülatörü (clock-enable, türetilmiş saat yok) |

### 3.9 Hata, reset ve sınır-durum sözleşmesi (Faz 0'da ISA ile birlikte dondurulur)

Bu bölüm, "spec'te yoksa formal kanıtlanamaz" ilkesiyle yazılmıştır: `no-deadlock` ve `arg-discipline` görevlerinin (6.7) kapsadığı her sınır durumu burada davranışa bağlanır.

#### 3.9.1 Geçersiz `msg_id`
Register haritası (ve native port) istemcisi keyfi değer yazabilir; sequencer her mesaj kabulünde `msg_id < MSG_COUNT` (k_fmtgen'in ROM başlığına yazdığı sabit) denetimi yapar. **Davranış:** mesaj **çıktısız düşürülür**, `err_cnt++` ve sticky `STATUS.BAD_MSG` seti; `G_EMIT_ERR_MSG=1` ise ROM'daki ayrılmış `"[bad msg]\r\n"` işaret mesajı basılır (bu mesaj k_fmtgen tarafından her imaja otomatik eklenir). Motor hiçbir durumda kilitlenmez; sonraki mesaj normal işlenir.

#### 3.9.2 Bozuk / rezerv µop
Motor, rezerv kodlamayla (`STR.mode=11`, rezerv uzatma-kelimesi, arity sınırı dışına taşan `arg_slot`) veya EOM'suz ROM bölgesi sonuyla karşılaşırsa: **halt yok, sonsuz döngü yok** — mesajın kalan µop'ları atlanır, **sentetik EOM** üretilir (`out_last=1` basılır, akış çerçevesi tüketici için daima kapanır), `err_cnt++` + sticky `STATUS.BAD_UOP`. Gerekçe: halt gözlemlenebilirliği öldürür, sessiz-atla çerçeve senkronunu bozar; "kes + çerçeveyi kapat + işaretle" üçünü de korur. Bu davranış `no-deadlock` formal görevinin varsayım setine girer: rastgele ROM içeriğiyle bile FSM ≤M çevrimde idle'a döner (6.7).

#### 3.9.3 ISA sürüm doğrulaması (mekanik, insan disiplini değil)
ROM imajının başlık sözcüğündeki `ISA_VER` alanı, RTL'deki `KP_ISA_VERSION` parametresiyle karşılaştırılır: **simülasyon/elaborasyonda** hem SV hem VHDL tarafında assert (uyumsuz imaj = anında kırmızı test); **donanımda** reset sonrası tek seferlik denetim — uyumsuzlukta çekirdek **güvenli-boş moda** girer (tüm mesajlar 3.9.1 yoluyla reddedilir, sticky `STATUS.ISA_MISMATCH` set). "Eski ROM + yeni RTL" kombinasyonu böylece hiçbir akışta sessiz çalışamaz.

#### 3.9.4 Reset ayrıntıları ve mesaj-ortası reset (flush sözleşmesi)
- **Ad/polarite/konvansiyon:** `rst_i` — senkron, aktif-yüksek; assert ve deassert saat kenarında (≥2 çevrim tutulur); asenkron reset yok (stil sözlüğü satırı, Bölüm 5). Çift-saat async-FIFO senaryosunda her bölgeye kendi **senkron-deassert'li** reset kopyası dağıtılır (2.1).
- **Flush sözleşmesi:** reset tüm kontrol durumunu atar — MSG FIFO ve TX FIFO pointer'ları sıfırlanır (**yarım tüketilmiş mesaj ve kuyruktaki mesajlar kaybolur**), gölge yazmaçlardaki bekleyen tetik/snapshot'lar temizlenir, `out_valid=0`, sayaçlar (`err_cnt/dropped_cnt`) sıfırlanır. Kısmi mesaj "tamamlanmaya çalışılmaz" — reset bir kurtarma değil, yeniden-başlangıç mekanizmasıdır.
- **UART hattı:** reset anında havadaki bayt **kesilir**, `tx` hattı anında idle-1'e çekilir → karşı uç **tek çerçeve hatası** görebilir. Bu bilinçli bir sadelik kararıdır ve Limitations'a yazılır; nazik-boşaltma isteyen sistem, reset öncesi `STATUS`'tan FIFO-boş bilgisini bekler (drain-then-reset deseni `integration.md`'de örneklenir).
- **HW tetik yeniden-ateşleme penceresi:** snapshot atomikliği tek çevrim için zaten tanımlı; **snapshot-sonrası grant bekleme penceresinin politikası:** varsayılan **en-eski-kazanır** — bekleyen snapshot korunur, aynı kaynağın yeni tetiği **yok sayılır ve `dropped_cnt++`** (drop sayacı bu vakayı **sayar**; sayaç tanımı "kabul edilemeyen her tetik"tir, FIFO-dolu vakasıyla aynı sayaç). `G_TRIG_LATEST=1` generic'i ile kaynak başına **en-yeni-kazanır** seçilebilir: yeni tetik snapshot'ın üzerine yazar, **ezilen mesaj yine `dropped_cnt`'e sayılır** (telemetri kaybı her iki politikada da görünürdür).

#### 3.9.5 Native port arity sözleşmesi
Mesaj kaydında `argc` alanı **yoktur**: arity'nin tek otoritesi ROM arity tablosudur (k_fmtgen üretir, 3.2.1'e göre `*` yuvaları dahil). Native istemci her zaman tam-genişlik `args` vektörü sürer; sequencer yalnız arity kadarını okur, fazlası yok sayılır. Böylece "istemcinin argc'si ROM'la çelişirse" hata sınıfı **yapısal olarak doğamaz** (AXIS ön yüzündeki `tlast` uyumsuzluğu ayrı konudur ve orada sayaç + yeniden-senkron zaten tanımlı, 3.7).

#### 3.9.6 Satır-içi `%s`'in fiziksel kanalı (Faz 3)
Mesaj kaydı **sabit genişlikte kalır** (değişken-uzunluklu MSG FIFO kaydı yok — FIFO kelime genişliği ISA gibi dondurulur). Satır-içi string baytları ayrı bir **STR-FIFO** (küçük EBR bayt-FIFO'su, `G_STR_FIFO_DEPTH`) üzerinden taşınır: istemci önce baytları STR-FIFO'ya yazar, mesaj kaydındaki ilgili arg yuvasına `{len}` konur; **mesaj kaydı ancak string baytları tamamen yazıldıktan sonra commit edilir** ("mesaj kabulünde string baytları donmuş" atomiklik sözleşmesinin gerçekleme aracı). Motor STR(satır-içi) µop'unda `len` kadar baytı STR-FIFO'dan akıtır — uzunluk önceden bilindiği için sağa-yaslı genişlik yine bedava. **Runtime parser modunda `%s`:** argüman **tablo-ID** olarak yorumlanır (ROM tablosuna indeks; aralık dışı ID → `"(null)"`); satır-içi mod parser'dan erişilemez, bellek-adresi semantiği hiçbir modda yoktur (Bölüm 4 tablosuna işlendi).

---

## 4. Belirteç / Özellik Destek Tablosu (C v2 ↔ HDL)

| C v2 belirteci/özelliği | C anlamı | HDL gerçekleme | Maliyet | Faz | Not |
|---|---|---|---|---|---|
| `%x` / `%X` | hex | nibble→ASCII mux, MSB-first, öncü-sıfır atlama | çok düşük | **1** | En ucuz; register dökümü ana kullanım — ilk hedef |
| `%c` | karakter | **`STR mode=CHR`** µop — ARG düşük baytı; genişlik/`-` STR pad yolundan (Bölüm 3.2) | ihmal edilebilir | **1** | ISA'daki kodlaması Faz 0'da dondurulur |
| `%s` (ROM) | string | ROM tablosu `{addr,len}`; NULL/geçersiz ID → `"(null)"` girdisi | ROM portu | **1** | Uzunluk derlemede bilinir → sağa-yaslı genişlik bedava |
| `%s` (satır-içi) | string | uzunluk-önekli bayt, **ayrı STR-FIFO yan kanalı**; commit-sonrası donmuş (Bölüm 3.9.6) | STR-FIFO (1 EBR) | **3** | MSG FIFO kaydı sabit genişlikte kalır |
| `%s` (runtime parser modunda) | string | argüman **tablo-ID** yorumu (aralık dışı → `"(null)"`); satır-içi ve bellek-adresi semantiği yok | — | **3** | Parser + `%s` kombinasyonunun tek tanımlı anlamı |
| `%%`, düz metin | literal | LIT µop (ROM'da erir) | — | **1** | Parser modunda ayrıca ele alınır |
| `%u` | işaretsiz ondalık | seri double-dabble | orta | **2** | BASE konfigin ilk taşı |
| `%d` / `%i` | işaretli ondalık | unsigned-çıkarma büyüklük + `-` + DD | orta | **2** | C'deki INT_MIN-güvenli desen birebir |
| bayraklar `- + boşluk 0 #` | alan biçimleme | üç dallı LAYOUT; `0`+prec ve prec=0&0 kuralları | orta | **2** | Bölüm 3.3 |
| genişlik, `.prec`, `*` | alan/kesme | 6-bit alanlar (63'e satürasyon, belgeli sapma); `*` ARG'dan — **ardışık-yuva konvansiyonu, Bölüm 3.2.1** | orta | **2** | Negatif `*` genişlik → `-` bayrağı + mutlak; negatif `*` prec → prec yok |
| `l` | 32-bit | µop `size` biti (16/32) | ~0 | **2** | Yuva zaten 32-bit; `l`'siz semantik Bölüm 2.1'de donduruldu; `size` `*` arglarına uygulanmaz (3.2.1) |
| `%o` | oktal | 3-bit dilim; `%#o` istisnası dahil | düşük | **2** | |
| `%b` / `%B` | ikili | 1-bit dilim (≤32 karakter) | düşük | **2** | Donanımda en doğal belirteç; oracle artık test edebiliyor |
| `%p` | işaretçi | `%#x` takma adı, sabit genişlik | ~0 | **2** | Bus adresi basmak anlamlı |
| bilinmeyen belirteç | yankı, arg tüketmez | parser modunda birebir; ROM modunda üretim hatası | — | **3** | |
| sondaki tek `%` | düşürülür | parser modunda aynı | — | **3** | |
| `h/hh` | yok sayılır | `k_fmtgen` yok sayar (uyarı) | — | — | C sözleşmesi |
| `k_snprintf` | tampona yaz + say | capture-BRAM sink + `msg_len` | düşük | **3** | Taşma: yazmayı kes, saymaya devam |
| `k_fprintf` / çoklu sink | sink seçimi | `out_dest` + demux | düşük | **3** | |
| `k_printf_lock/unlock` | atomiklik | mesaj-taneli arbiter | orta | **3** | Yapısal çözüm |
| `K_PRINTF_ENABLE_*` | opt-in derleme | `G_EN_HEX/OCT/BIN/PTR/STR/DEC/RUNTIME_FMT` + `generate` | — | 1–3 | RTL'de **ondalık bile kapatılabilir** (DD alanını geri kazanmak için) — C'den ince kapılama |
| geçersiz `msg_id` / bozuk µop | (C'de yok) | düşür + sticky STATUS + `err_cnt`; ops. `"[bad msg]"` (Bölüm 3.9.1–3.9.2) | düşük | **1** | Donanıma özgü hata sınıfı — Faz 1'den itibaren spec'li |
| `%f %e %g`, `%n`, `ll` | yok | **yok** | — | — | C ile simetrik Limitations |

---

## 5. VHDL–Verilog İkizlik Stratejisi

Elenen seçenekler: iki bağımsız elle RTL (sessiz drift) ve otomatik çeviri (okunmaz kod, "VHDL kullanıcıya kaynak" vaadini boşa düşürür). Seçilen: **altın + bakımlı el portu, eşdeğerliği makine zorlar.**

- **Altın dil SystemVerilog** (sentezlenebilir, Verilog-2005-uyumlu çekirdek alt küme; SV interface yok; assertion'lar ayrı `bind` dosyalarında, sentezden dışlanır). Gerekçe: Verilator (en hızlı sim, fuzz'ı erken açar) ve Yosys akışı Verilog-öncelikli; alan/timing kalibrasyonu bu ağaçtan.
- **VHDL-2008 birinci sınıf el portu, ayrı fazda** (Faz 2): her release'te aynı cocotb barajından geçer. Açık akışta sentezi `ghdl-yosys-plugin` ister — çalışır ama kırılgan; VHDL alan sayıları "bilgilendirici", bağlayıcı sayılar SV akışından. Diamond/Vivado kullanıcıları VHDL'i doğrudan sentezler.
- **Yapısal ayna kuralı:** iki ağaçta birebir aynı modül/entity adları, aynı dosya-başına-modül bölünmesi, aynı port adları. **İnsan disiplinine ek mekanik denetim — `hdl-mirror` CI işi:** `tools/k_portdiff.py`, iki ağaçtan modül/entity envanterini ve port imzalarını (ad, yön, genişlik, generic listesi) çıkarır (SV tarafı Verible syntax-dump'ından, VHDL tarafı GHDL/pyVHDLModel'den) ve diff'ler; fark = kırmızı build. PR şablonu kuralı yürürlükte kalır: **"SV değiştiyse VHDL eşleniği veya `port-bekliyor` etiketi"** — ama etiket bir borç kaydıdır, muafiyet değil: **release barajı olarak, açık `port-bekliyor` etiketi varken release tag'i kesilemez** (tag workflow'u etiket sorgusuyla bloklar; `hdl-mirror` bu PR'larda "bilinen-fark listesi" dosyasıyla yeşile zorlanır, liste release'te boş olmak zorundadır).
- **Eşdeğerlik mekanizması:** tek cocotb takımı; GHDL/nvc VHDL'i, Verilator/Icarus SV'yi sürer; üçlü bayt-eşitliği **C = SV = VHDL** (Bölüm 6.5). Sözleşme: bayt akışı eşitliği zorunlu, çevrim-doğruluğu (latency) serbest — mikro-mimari ayrışabilir, akış ayrışamaz. (VHDL↔SV netlist miter'i pratik değil; akış-diferansiyeli esastır.) ISA sürüm alanı da mekanik doğrulanır (Bölüm 3.9.3) — iki RTL aynı `KP_ISA_VERSION`'ı taşımazsa elaborasyon düşer.

Adlandırma/lint standartları (`docs/hdl/style.md`'de dondurulur):

| Konu | SV | VHDL | Not |
|---|---|---|---|
| Lint/format | Verible (lowRISC stili) | VSG + `vsg.yaml` | İkisi de CI'da **bloklayıcı**; araç tedariki/pinlemesi Bölüm 6.9 |
| Dosya/modül | `kp_core.sv` / `module kp_core` | `kp_core.vhd` / `entity kp_core`, mimari `rtl` | Taban adlar birebir; `hdl-mirror` diff'inin girdisi |
| Portlar | `_i/_o` ekleri, aktif-düşük `_n` | aynı | Diller arası tek sözlük |
| **Saat/reset** | `clk_i`; **`rst_i` senkron aktif-yüksek**, senkron assert+deassert; asenkron reset yasak | aynı | Bölüm 3.9.4; aktif-düşük gereken kart sınırında üst modül çevirir (`rst_ni` çekirdeğe girmez) |
| Generic/parametre | `UPPER_SNAKE` (`G_ARG_W`) | aynı | lowRISC CamelCase kuralından bilinçli sapma — çapraz-dil diff için; stil dokümanına kaydedilir |
| Testbench | cocotb (Python), `hdl/tb/` | ortak | Dil-özel TB yazılmaz |

---

## 6. Doğrulama Stratejisi

### 6.1 Açılış argümanı: RTL, C'nin test edemediğini test eder

C fuzzer'ı (`tests/fuzz_k_printf.c`) oracle'ı host `snprintf` olduğu için `%b/%B`, `%p`, NULL-`%s` ve bilinmeyen-belirteç davranışını **dışlamak zorundaydı**. RTL doğrulamasında oracle **`k_snprintf`'in kendisi** — yani tam belirteç kümesi, NULL-string davranışı ve yankı sözleşmesi dahil, **ilk kez tam diferansiyel test edilebilir**. Doğrulama zinciri: `snprintf → C k_printf → k_printf_hdl`; altın model zaten CI'da snprintf'e karşı doğrulanan kod olduğundan güven zinciri kopmaz.

### 6.2 Altın model: C kütüphanesi, cffi üzerinden (+ C shim yedeği)

- `hdl/gold/`: `cc -fPIC -shared -std=c11 -Iinclude src/k_printf.c -o libk_printf_gold.so`. Python tarafında **cffi** (`ffi.cdef` ile vararg prototipi — ctypes'a tercih: variadic çağrılarda tip-terfi hataları sessiz uyumsuzluk üretir; ARM64/Apple Silicon'da ctypes-vararg ayrıca kırılgandır).
- **Yedek plan (baştan yazılı):** FFI vararg sorunlarını tümüyle atlayan, stdin'den `(fmt, args)` okuyup `k_snprintf` çıktısı basan sabit-ariteli minik bir C harness binary'si.
- Akış (mesaj başına): üreteç `(fmt, args)` üretir → `k_fmtgen` µop'a derler, TB sürer → RTL baytları toplanır → aynı `(fmt, args)` ile `k_snprintf` çağrılır → **bayt-bayt eşitlik + `msg_len == k_snprintf dönüşü`** assert edilir.
- **Uyumsuzluk disiplini:** her uyumsuzluk `{seed, fmt, args, rtl_bytes, gold_bytes}` JSONL kaydı olarak `regress/corpus/` altına yazılır ve **kalıcı yönlendirilmiş regresyon** vakasına döner — C tarafındaki fuzz→regresyon disiplininin aynısı.
- **Opt-out simetrisi (`test_optout.c`'nin donanım karşılığı):** RTL `G_EN_X=0` ile elaborate edilirken altın `.so` aynı `-DK_PRINTF_ENABLE_X=0` ile derlenir; "kapalı belirteç yankılanır, argüman tüketmez" davranışı **konfigürasyon başına** diferansiyel doğrulanır. CI matrisi en az: `hepsi-açık`, `yalnız-çekirdek`, `BIN=0,PTR=0`.

### 6.3 Constrained-random üreteç: fuzz şemasının Python portu

`fuzz_k_printf.c`'nin 8-baytlık çözme şeması (bayt0=bayraklar, bayt1=genişlik+`*`, bayt2=hassasiyet+`*`, bayt3=belirteç+`l` biti, bayt4–7=32-bit değer LE, kalan baytlar `%`'siz yazdırılabilir literal) **birebir Python'a taşınır**. İki getiri:

1. **İki yönlü korpus paylaşımı:** C libFuzzer korpusundaki her dosya RTL testinde doğrudan oynatılır; RTL'de bulunan her uyumsuzluk C fuzzer'ına tohum olarak geri akar.
2. **Çapraz sağlama (Faz 0 çıkış kriteri):** aynı 8 bayt için Python üretecinin kurduğu format stringi, C fuzzer'ınkiyle bayt-bayt aynı olmalı — üreteç portu böyle birim-test edilir.

Genişletmeler: belirteç alfabesi `diuxXobBcsp%`'ye büyür (oracle artık izin veriyor); NULL-string kodu ve bilinmeyen/kapalı belirteç de üretilir; **hatalı `msg_id` ve bozuk-µop enjeksiyonu** ayrı bir negatif-test modu olarak eklenir (beklenen: 3.9.1–3.9.2 davranışı, altın modelle değil spec'le karşılaştırılır). `*` argümanları arity'ye dahil üretilir ve int16 aralığına kısıtlanır (3.2.1). Üretecin çıktısına donanım boyutları eklenir: `out_ready` geri-basınç desenleri ve `msg/arg` girişlerinde rastgele valid boşlukları — **fonksiyonel uzay × zamanlama uzayı birlikte taranır**.

### 6.4 16-bit sözleşmesi ve sınır vektörleri

`l`'siz dönüşümler için üreteç değerleri **int16/uint16 aralığına kısıtlar** (Bölüm 2.1'deki dondurulmuş semantik) — aralık içinde RTL ve host altın modeli bayt-bayt aynıdır. Sabit yönlendirilmiş sınır vektörleri: `INT16_MIN`, `UINT16_MAX`, `INT32_MIN`, `UINT32_MAX`, `0`, `0xAAAA5555`; ayrıca `width == G_MAX_FIELD` tam-sınır vakası (ötesi "spec dışı" olarak belgelenir) ve `%*.*d`'nin `G_ARGC_MAX` tavanına tam oturduğu 3-yuva vakası (3.2.1).

### 6.5 Geri-basınç değişmezi, DROP belirlenimciliği ve HDL'ler-arası eşdeğerlik

- **Değişmez (koşullu):** **STALL modunda — ve DROP modunda taşmanın hiç yaşanmadığı koşularda —** çıkan bayt dizisi `out_ready` deseninden bağımsızdır. Aynı mesaj en az **{hep-1, rastgele}** iki desenle koşulur, bayt akışları diff'lenir; desen kütüphanesi: hep-1, hep-0-sonra-1, rastgele duty, patlamalı. (Önceki "koşulsuz bağımsızlık" ifadesi DROP için yanlıştı: uzun stall'da *hangi* mesajların düştüğü ready desenine bağlıdır — bu düzeltme değişmezin dürüst sınırıdır.)
- **DROP modunun ayrı belirlenimcilik sözleşmesi (mesaj bütünlüğü):** (a) her mesaj **ya-hep-ya-hiç** — çıkışa mesajın hiçbir kısmi parçası sızamaz, her çıkan çerçeve tam ve bayt-bayt doğrudur; (b) çıkış akışı, kabul edilen mesaj dizisinin **mesaj-taneli alt dizisidir** (sıra korunur); (c) `dropped_cnt` == kabul edilip basılmayan mesaj sayısı (3.9.4'teki yeniden-tetikleme düşüşleri dahil). DROP testleri bayt-diff yerine bu üç maddeyi assert eder; formal karşılığı `drop-atomicity` görevidir (6.7).
- **Üçlü diff:** aynı sabit tohum iki gerçeklemeye sürülür; TB'ler mesaj-sınırlı bayt loglarını JSONL'e döker, karşılaştırıcı script **VHDL ↔ SV ↔ altın** üçlüsünü diff'ler. DROP-modu eşdeğerliği bayt değil **mesaj-küme düzeyinde** karşılaştırılır (aynı ready deseni + aynı tohum altında iki RTL'in düşürdüğü mesaj kümeleri de eşit olmalıdır — mikro-mimari farkı buraya sızarsa bilinçli olarak yakalanır).

### 6.6 Simülatör matrisi

| Gerçekleme | Simülatör | Rol | CI seviyesi |
|---|---|---|---|
| SV | **Verilator** | Hız — uzun fuzz koşuları (2-durumlu) | PR'da bloklayıcı |
| VHDL | **GHDL** (`--std=08`) | VHDL referansı + X-yayılım nöbeti | PR'da bloklayıcı |
| SV | **Icarus** | 4-durum, X-yayılım nöbeti | PR'da kısa dilim (1k mesaj); tam koşu gecelik |
| VHDL | **nvc** | İkinci bağımsız VHDL yorumu + kapsam | Gecelik; **kırılırsa bloklamaz** |

Verilator 2-durumlu olduğu için init-edilmemiş-register hatalarını maskeler → fuzz'ın bir dilimi **zorunlu olarak** Icarus/GHDL'de X-yayılım nöbeti olarak koşar. Sözleşme: bayt akışı eşit, latency serbest.

### 6.7 Formal: SymbiYosys görev tablosu

Araç zinciri: sby + Yosys + smtbmc; SV özellikleri `read -formal` (SVA alt kümesi: `|=>`, `$stable`, `$past`), VHDL tarafı PSL ile `ghdl-yosys-plugin` üzerinden — **aynı özellik seti iki HDL'de de koşar**.

| sby görevi | Mod | Özellik |
|---|---|---|
| `handshake` | prove | `out_valid && !out_ready \|=> out_valid && $stable(out_data)`; aynısı tüketim tarafı `msg/arg_ready` için |
| `no-deadlock` | prove | Sayaçlı sınırlı-adalet varsayımı ("ready her N çevrimde ≥1 kez 1") altında her meşgul FSM durumu ≤M çevrimde terk edilir; DD iterasyon sayacı sınırlı. **Kapsama, 3.9.1–3.9.2 sayesinde artık kanıtlanabilir olan vakalar dahildir:** rastgele (geçersiz) `msg_id` ve rastgele ROM içeriği (rezerv/bozuk µop) altında da motor idle'a döner — davranış spec'te tanımlı olduğu için varsayım değil, kanıt konusudur |
| `arg-discipline` | bmc | Mesaj başına tüketilen ARG sözcüğü sayısı == µop'ların beyanı; beyan formülü `1 + w_from_arg + p_from_arg` (ardışık-yuva konvansiyonu, 3.2.1) — C v1'deki vararg-desync hata sınıfının **formal kapatılması** |
| `count-consistency` | bmc | `msg_len` == EOM'a kadar yayınlanan bayt sayısı |
| `drop-atomicity` | bmc | DROP modunda: EOM'suz mesaj parçası çıkışa sızamaz (her `out_last` çerçevesi tam bir mesaja karşılık gelir); düşürülen her mesaj için `dropped_cnt` tam +1 artar (6.5'teki mesaj-bütünlüğü sözleşmesinin formal yüzü) |
| `reach` | cover | Her FSM durumu, her belirteç yolu, `width==G_MAX_FIELD`, prec=0&değer=0 yolu, **BAD_MSG/BAD_UOP yolları ve sentetik-EOM üretimi** erişilebilir |

Ek: async FIFO (kullanılırsa) boşken-okuma/doluyken-yazma imkânsızlığı + iki bölgeli reset senaryosu (3.9.4).

### 6.8 Kapsam

- **Fonksiyonel** (cocotb-coverage): belirteç × {`l` var/yok} × bayrak sınıfı × genişlik sınıfı {yok, 1–9, 10–63, `*`, negatif-`*`} × hassasiyet sınıfı {yok, 0, 1–63, `*`, negatif-`*`} + 6.4 sınır vektörleri + hata yolları (BAD_MSG, BAD_UOP, retrigger-drop); belirteç×bayrak çaprazı %100 hedef.
- **Kod:** Verilator `--coverage` (SV), nvc `--cover` (VHDL); `kp_core` FSM'de %100 statement/branch hedefi.
- **Formal cover:** `reach` görevi, sim'in kör noktası olan "hiç üretilmemiş girdi" sınıfını kapatır.
- **Birim seviyesi:** ondalık dönüştürücü 16-bit'te **tüketici (exhaustive)**, 32-bit'te rastgele Python `int`'e karşı; emit/pad aritmetiği genişlik==gövde±1 sınır vakalarıyla. `$display`/`textio` yalnız TB iz kaydıdır — asla oracle değil.

### 6.9 Yerel doğrulama hedefleri (`make -C hdl`)

> **Proje kuralı: GitHub CI yok.** Doğrulama yereldedir (C tarafındaki `make test` +
> `make fuzz-standalone` ile simetrik). Bu bölüm, planın orijinalindeki "CI işleri"
> tablosunu **yerel `make` hedeflerine** çevirir; her hedef, geliştiricinin PR/commit
> öncesi elle (veya bir `pre-commit`/`git hook` ile) koşturacağı, dönüş kodu 0 = geçti
> olan bağımsız bir adımdır. "Bloklayıcı" = "commit öncesi geçmesi zorunlu".

Araç temeli (yerelde mevcut olması yeterli; sürümler `hdl/README.md`'de not edilir):
- **Icarus Verilog** (`iverilog`/`vvp`) — SV çekirdek simülasyonu (bu makinede 13.0).
- **GHDL** (`--std=08`) — VHDL çekirdek simülasyonu + X-yayılım nöbeti (bu makinede 5.1.1).
- **Python 3 + cffi** — altın model köprüsü ve constrained-random üreteç.
- **Opsiyonel (varsa):** Verilator (hızlı fuzz), yosys+nextpnr (alan/fmax raporu),
  sby (formal), nvc (ikinci VHDL yorumu). Yoksa ilgili hedef atlanır (skip), fail değil.

| Yerel hedef | İçerik | Zorunluluk |
|---|---|---|
| `make -C hdl fmtgen` | `k_fmtgen.py`: `messages.h` → µop ROM/lit/string `.mem` + ID header; **üretim anında C `libk_printf` ile deneme-basma** (drift kilidi) | commit öncesi |
| `make -C hdl gold` | Altın `.so` derle (konfig başına `-DK_PRINTF_ENABLE_*`); cffi köprüsü | commit öncesi |
| `make -C hdl sim-sv` | Icarus: yönlendirilmiş + rastgele mesajlar; her mesaj RTL baytları ↔ C `k_snprintf` bayt-bayt; negatif testler (BAD_MSG/BAD_UOP) | commit öncesi (bloklayıcı) |
| `make -C hdl sim-vhdl` | GHDL: aynı testbench mantığı, VHDL ikiz; X-yayılım nöbeti | commit öncesi (bloklayıcı) |
| `make -C hdl equiv` | Aynı tohum → SV/VHDL bayt logları → **üçlü diff (C=SV=VHDL)**; DROP modunda mesaj-küme karşılaştırması (6.5) | commit öncesi |
| `make -C hdl test` | Yukarıdakilerin hepsi sırayla (C tarafındaki `make test`'in HDL karşılığı) | commit öncesi |
| `make -C hdl fuzz` | Deterministik tohumla N-mesaj constrained-random diferansiyel (Verilator varsa hızlı, yoksa Icarus dilimi) | opsiyonel/periyodik |
| `make -C hdl synth-report` | yosys+nextpnr varsa alan/fmax raporu Bölüm 3.5 bütçeleriyle karşılaştırılır; yoksa skip | opsiyonel (araç varsa) |
| `make -C hdl formal` | sby varsa 6.7 görevleri; yoksa skip | opsiyonel (araç varsa) |
| `make -C hdl lint` | Verible/VSG varsa; yoksa skip | opsiyonel (araç varsa) |

Oracle bağımlılığı yereldeyken de geçerlidir: `src/k_printf.c` değişince `make -C hdl test`
yeniden koşulmalıdır (altın model odur). Bu bağı bir `git pre-commit` hook'u ya da kök
`Makefile`'a `make -C hdl test` çağrısı ekleyerek otomatikleştirmek serbesttir — ama
**GitHub Actions eklenmez**.

---

## 7. Proje Yapısı & Build

### 7.1 Monorepo kararı ve ayrılma kriterleri

**Karar: aynı repo, `hdl/` dizini.** Gerekçe: (1) **Oracle bağımlılığı** — RTL testinin beklenen çıktısı host'ta derlenen `libk_printf`'ten gelir; monorepoda C'ye dokunan PR, HDL diferansiyelini aynı koşuda kırar, grammar drift en erken anda yakalanır. (2) **Atomik sözleşme değişikliği** — µop ISA'ya alan eklemek = codegen + iki RTL + C header + spec; tek commit'te atomik, iki repoda "önce hangisi merge olacak" dansı. (3) **Ölçek** — iki taraf da yüzlerce satır mertebesinde; submodule yükü haksız.

**Ayrılma kriterleri (şimdiden yazılır):** (a) HDL sürüm kadansı C'den bağımsızlaşırsa, (b) FuseSoC kütüphanesi olarak dış tüketim C klonunu yüke çevirirse, (c) vendor paketleri repoyu şişirirse → `k_printf_hdl` reposuna taşınır; µop ISA spec'i ve `k_fmtgen.py` ana repoda kalır, HDL repo pinli tüketir.

### 7.2 Dizin düzeni

```
.github/workflows/ci.yml   (Faz 0'da kurulur: C işleri + HDL işleri — Bölüm 6.9)
hdl/
  rtl/sv/        kp_core.sv  kp_seq.sv  kp_numfmt.sv  kp_emit.sv  kp_arb.sv  kp_uart_tx.sv ...
  rtl/vhdl/      kp_core.vhd ... (birebir aynı taban adlar — yapısal ayna, hdl-mirror denetler)
  tb/            cocotb testleri (ortak, dil-bağımsız) + geri-basınç desen kütüphanesi
  gold/          libk_printf_gold derleme betikleri + cffi sarmalayıcı + C shim yedeği
  fmt/           messages.h (X-macro örnek mesaj seti)
  gen/           k_fmtgen çıktıları (commit'lenir: tekrar-üretilebilirlik + araçsız kullanıcı)
  formal/        *.sby görevleri (6.7)
  boards/        .pcf/.lpf/.xdc + iCE40/ECP5/Artix örnek üst modülleri
  regress/corpus/  JSONL uyumsuzluk kayıtları (kalıcı yönlendirilmiş regresyon)
  k_printf_hdl.core   Makefile   verible.rules   vsg.yaml   requirements-hdl.txt
tools/k_fmtgen.py   tools/k_portdiff.py   (dizin Faz 0'da açılır — bugün mevcut değil)
docs/hdl/        fmt_isa.md  style.md  integration.md  (WaveDrom diyagramları)
```

### 7.3 Format tablosu paylaşımı: tek doğruluk kaynağı + grammar-drift çift kilidi

Tek kaynak, X-macro'lu `fmt/messages.h` (hem C hem codegen okur):

```c
/* K_MSG(sembol, "format", arity) */
K_MSG(MSG_BOOT,     "k_printf_hdl v%d.%d hazir\r\n",  2)
K_MSG(MSG_TICK_REG, "Tick: %lu, Reg: %#010lX\r\n",    2)
K_MSG(MSG_PORT,     "Port: %08b\r\n",                 1)
```

`k_fmtgen.py` (saf Python, bağımlılıksız) çıktıları — hepsi "GENERATED" damgalı: (1) `fmt_rom.mem` + `lit_pool.mem` + string tablosu — `$readmemh`/VHDL textio ile okunan, **iki dile ortak** vendor-bağımsız veri dosyaları (başlık sözcüğünde `ISA_VER` + `MSG_COUNT`, Bölüm 3.9.3); (2) `fmt_rom_pkg.sv` / `.vhd` — yalnız sabitler (`MSG_*` ID'leri, boyutlar, arity tablosu — `*` yuvaları dahil, 3.2.1); (3) `messages_ids.h` + `k_printf_hw.h` — C istemciler ve TB için; (4) `messages_report.md` — insan-okur envanter + yuva doluluk raporu. Arity beyanındaki `K_MSG` arity alanı ile k_fmtgen'in formattan hesapladığı arity çelişirse **üretim hatası** (tek otorite hesaplanan değerdir; alan insan-okur çapraz sağlamadır).

**Grammar-drift çift kilidi:** (a) `k_fmtgen`, ürettiği **her formatı üretim anında host `libk_printf` ile deneme-basar** — C parser'ın reddettiği/farklı yorumladığı format üretimi durdurur; codegen C'ye *danışır*, grameri *yeniden uygulamaz* (Python kopyası yalnız encode eder). (b) CI diferansiyel testi her mesajı RTL'de koşturup baytları yine C çıktısıyla karşılaştırır. Doğruluk otoritesi iki noktada da C'de kalır.

### 7.4 Paketleme ve dokümantasyon

- **FuseSoC `.core` + saf Makefile, ikisi birden.** Tek `.core`, hedef başına: `sim_sv / sim_vhdl / lint / synth_ice40`; generic'ler `.core` parametresi olarak dışa açık. Makefile, C tarafındaki `make lib/test/fuzz` geleneğinin aynası: `make -C hdl sim-sv sim-vhdl lint synth-report fmtgen`. hdlmake reddedildi (bakımı zayıflıyor); Vivado IP paketi (`component.xml`) talep gelirse Faz 3 sonu.
- **Dokümantasyon** (İngilizce kanonik + Türkçe gecikmeli özet düzeninin devamı): `hdl/README.md` (EN, kanonik — özellikler, hızlı başlangıç, port/generic tabloları, register haritası, sentez raporu özeti ve **dürüst Limitations bölümü**: runtime format varsayılan kapalı, ROM=bitstream, float/64-bit yok, `G_MAX_FIELD=63` sapması, reset-anı UART çerçeve hatası olasılığı — 3.9.4); `docs/hdl/fmt_isa.md` (dondurulmuş ISA + 3.9 hata/reset sözleşmesi — değişiklik = minor sürüm); `docs/hdl/integration.md` (üç yüzeyin WaveDrom diyagramları, drain-then-reset deseni, uart_ringbuf geçiş tablosu — Bölüm 3.8); `docs/README.hdl.tr.md` ("İngilizce'nin gerisinde kalabilir" etiketiyle). Kök README'ye "Hardware (HDL) core" bölümü; `CHANGELOG.md`'de release başına `### HDL` alt başlığı; repo SemVer'i ortak.

---

## 8. Fazlı Yol Haritası

> Faz 0 sözleşme fazıdır (**RTL kodu yok** — araç, model ve CI kodu *vardır*: k_fmtgen, cffi sarmalayıcı, fuzz-port ve sentez spike'ı yazılım/altyapı işidir); Faz 1/2/3'ün her biri **bağımsız teslim edilebilir** — her fazın sonunda çalışan, CI'lı, belgeli bir ürün vardır.

### Faz 0 — Sözleşmeler + araçlar + altın model (RTL kodu yok; çıkış kriterleri net)
1. µop ISA v1 dondurma (sürüm alanı + rezerv kodlamalar + **`%c`=STR/CHR kodlaması** + **`*` ardışık-yuva konvansiyonu, 3.2.1) + **hata/reset sözleşmesi (Bölüm 3.9: geçersiz msg_id, bozuk µop, flush, retrigger politikası)** + C-sapma listesi (`G_MAX_FIELD=63`, `%s` modeli) + **`l`'siz=16-bit semantik cümlesi** (Bölüm 2.1) — `docs/hdl/fmt_isa.md`
2. `docs/hdl/style.md` (adlandırma sözlüğü **+ saat/reset konvansiyonu satırı**, lint kuralları) + dizin iskeleti + araç tedarik/pinleme: OSS CAD Suite sürümü, **Verible ayrı-release kurulum adımı**, **`pip install vsg`** dahil `requirements-hdl.txt` (Bölüm 6.9)
3. **Temel C CI'ının kurulması ve GitHub ile senkronu:** repoda bugün `.github/workflows/` yok — `ci.yml` v0 (`host-test`, `fuzz-smoke`, `msp430-cross`) yazılır, yeşile çekilir; HDL işleri sonraki fazlarda bu dosyaya eklenir. `tools/` dizini de bu adımda açılır
4. `k_fmtgen.py` v0: format → µop/ROM imajları (ISA_VER başlıklı) + ID header + arity tablosu (`*` yuvaları dahil) + **deneme-basma kilidi** (7.3a)
5. Altın model altyapısı: konfig-başına `.so` + cffi sarmalayıcı + C shim yedeği; `tests/test_k_printf.c` vakaları Python'dan geçiyor
6. Fuzz şemasının Python portu (+ negatif-test modu iskeleti: BAD_MSG/BAD_UOP enjeksiyonu)
7. Sentez spike'ı: boş kabuk + FIFO + çıkış aşaması — Bölüm 3.5 tahminlerinin ilk kalibrasyonu **ve fmax eşiklerinin ilk gerçeklik testi**
8. **Çıkış kriterleri:** üreteç, C fuzzer'la 8-bayt→format-string **bayt-bayt eşdeğerliği** birim testinden geçiyor; altın model test vakalarını doğru basıyor; **CI iskeleti yeşil — "yeşil"in tanımı:** C işleri gerçek testleri koşuyor; `hdl-lint` sentez spike'ının kabuk RTL'i üzerinde gerçek Verible+VSG koşuyor; `hdl-sim` aynı kabuğun cocotb duman testini (reset→idle→boş mesaj reddi) koşuyor. Yani boş-geçen iş yok: yeşil, *tasarımın doğruluğunu değil*, **araç tedarik+pin+cache zincirinin uçtan uca çalıştığını** kanıtlar — Faz 1'de ilk gerçek RTL geldiğinde altyapı sürprizi kalmaz

### Faz 1 — MINI dikey dilim (SV) — teslim: FPGA'da çalışan "Hello %x"
9. MSG FIFO + sequencer (**msg_id geçerlilik denetimi + BAD_MSG yolu, 3.9.1**) + LIT/EOM + `%x %X %%` + `%c` (STR/CHR) + ROM-`%s` + valid/ready çıkışı (SV) — **MINI konfig tanımıyla birebir** (Bölüm 3.5)
10. `kp_uart_tx` (N.F baud akümülatörü) + TX FIFO + iCE40/Artix örnek top'ları; kartta bring-up (CRC'li mesaj testi); reset-flush davranışı kartta gözlenir (3.9.4)
11. cocotb diferansiyel **ilk günden** (Verilator + Icarus dilimi); JSONL log + geri-basınç desen altyapısı + BAD_MSG/BAD_UOP negatif testleri
12. **Kalibrasyon döngüsü:** iCE40 sentez raporu vs **MINI bütçesi (180–300 LUT4)** — sapma >%25 ise Bölüm 3.4 hileler listesine dön; `hdl-synth` alan **ve fmax** regresyonu CI'da MINI için bağlayıcı hale gelir (BASE/FULL bütçeleri henüz bağlanmaz — o bloklar yok)
13. **Teslim:** MINI çekirdek + UART, donanımda doğrulanmış, CI'lı, `hdl/README.md` ilk sürüm

### Faz 2 — Tam özellik seti (SV) + VHDL ikizi — teslim: iki dilde eşdeğer tam çekirdek
14. Seri double-dabble + `%u`, `%d/%i` (unsigned-çıkarma negasyonu), `size` biti (`l`)
15. Bayraklar/genişlik/`.prec`/`*` (ardışık-yuva, 3.2.1) — üç dallı LAYOUT, `0`+prec kuralı, prec=0&0 kuralı, satürasyon; `ndigits` öncelik kodlayıcısı. **Bu maddenin sonunda BASE konfig tanımı tamamlanır → BASE bütçesi (300–420) ve dürüstlük eşiği CI'da bağlayıcı olur** (3.5)
16. `%o` (`%#o` istisnası), `%b/%B`, `%p`; opt-out generic'leri + konfig matrisi testleri
17. Fuzz alfabesi tam kümeye genişler (`bBp` + NULL-string — C'nin test edemediği bölge); fonksiyonel kapsam modeli devrede
18. **VHDL-2008 portu** (yapısal ayna); GHDL yeşil; `hdl-equiv` üçlü diff (C=SV=VHDL) + **`hdl-mirror` port-imza diff'i** CI'da zorunlu baraj
19. SymbiYosys görevleri (handshake / no-deadlock / arg-discipline / count-consistency / drop-atomicity / reach) iki HDL cephesinde
20. **Teslim:** tam belirteç kümesi, iki dil, formal + eşdeğerlik + ayna CI'ı, ECP5/Artix karakterizasyonu ile güncellenmiş bütçe ve fmax tabloları

### Faz 3 — Sistem özellikleri + entegrasyon + paketleme — teslim: entegrasyon-hazır paket
21. Çok kaynaklı donanım tetik: 1-çevrim atomik snapshot + mesaj-taneli arbiter + kaynak-tipine-göre DROP(`dropped_cnt`)/STALL politikası + **retrigger penceresi politikası (en-eski-kazanır / `G_TRIG_LATEST`, 3.9.4)**
22. Capture-BRAM sink (`k_snprintf` karşılığı) + `out_dest` demux (`k_fprintf` karşılığı)
23. Runtime ASCII parser ön-ucu (`G_EN_RUNTIME_FMT`) — bilinmeyen-belirteç yankısı, sondaki-`%`, kapalı-belirteç sözleşmeleri C ile birebir diferansiyel test edilir; **parser modunda `%s` = tablo-ID sözleşmesi** (3.9.6)
24. Satır-içi `%s`: **STR-FIFO yan kanalı + commit-sonrası-donmuş sözleşmesi (3.9.6)**; genel bellek okuma portu **ayrı adaptör** olarak (opsiyonel)
25. Register haritası (+`STATUS` sticky bitleri/sayaçlar, 3.7) + write-to-fire `SEND`; AXI-Lite ve Wishbone adaptörleri; AXIS paket ön yüzü; `k_printf_hw.h` softcore köprüsü (vitrin: PicoRV32/NEORV32/LiteX)
26. Opsiyonel: gray-pointer async FIFO (+sby kontrolü + **iki bölgeli reset senkronu, 3.9.4**), **`kp_cdc_trig` tetik CDC adaptörü (2.1)**, `G_DD_PARALLEL`, `G_ROM_WRITABLE` değerlendirmesi, Vivado IP paketi
27. **Teslim:** FuseSoC paketi, tam doküman seti (EN kanonik + TR özet + Limitations), nightly fuzz + korpus geri-besleme döngüsü işler halde

---

## 8b. Uygulama durumu (2026-07-18)

Plan hayata geçirilmeye başlandı; **Faz 0 + Faz 1'in dikey diliminin çalışan, yerel olarak
doğrulanmış bir gerçeklemesi** repoda (`hdl/`, `tools/k_fmtgen.py`, `docs/hdl/`). Özet:

- **µop ISA v1 donduruldu** — `docs/hdl/fmt_isa.md`; her iki RTL ve codegen birebir bu alanları uygular.
- **`k_fmtgen.py`** — `hdl/fmt/messages.h` → µop ROM + literal/string havuzları + string tablo + ID/boyut header'ları (SV `.svh` + VHDL paketi) + **C altın dispatch'i** + yönlendirilmiş/rastgele test vektörleri; desteklenmeyen format = üretim hatası (gramer otoritesi C'de).
- **Altın model** — `hdl/gold/kp_gold.c` gerçek `k_snprintf`'i linkler; oracle zinciri `snprintf → C k_printf → k_printf_hdl`.
- **İki RTL çekirdek** — `hdl/rtl/sv/kp_core.sv` (SystemVerilog) ve `hdl/rtl/vhdl/kp_core.vhd` (VHDL-2008 yapısal ayna). Belirteçler `%d %i %u %x %X %o %b %B %p %c %s %%` + literal; bayraklar `- 0 # + boşluk`; genişlik 0..63; `l` (32-bit). Ondalık **seri double-dabble** (bölücü yok). INT_MIN-güvenli büyüklük, C'nin üç-dallı yerleşimi, `0`+precision ve `%#o` kuralları birebir. Kayıtlı valid/ready + geri-basınç.
- **Doğrulama (yerel, CI yok):** `make -C hdl test` → **165/165** diferansiyel vektör SV (Icarus, rastgele geri-basınçlı) ve VHDL (GHDL) için C altın modeline bayt-bayt eşit; **üçlü diff C = SV = VHDL** geçiyor (bayt akışı `ready` zamanlamasından bağımsız kanıtlandı).
- **Henüz yok (dürüst):** `.precision`, `*`, runtime parser, tetik/arbiter, capture/register-map/AXI ön yüzleri, sentez/alan/fmax sayıları. Hata yolları (geçersiz `msg_id`/bozuk µop) çekirdeklerde var ama TB'de yönlendirilmiş negatif testle sürülmedi (Faz 2). `hdl/README.md`'de "Verification status" bölümünde tekrar edildi.

Sonraki adımlar Faz 2 sırasını izler: `.prec`/`*`, negatif testler, opt-in generic'ler, ardından
tetik/arbiter ve sistem ön yüzleri. Her adım `make -C hdl test`'i yeşil tutmalıdır.

---

## 9. Riskler ve Açık Sorular

| Konu | Risk | Önlem / karar mekanizması |
|---|---|---|
| µop ISA'nın faz ortasında değişmesi | codegen + iki RTL + TB dört yerde kırılır | Faz 0'da sürüm alanıyla dondur; rezerv kodlamalar; **ROM başlığı ISA_VER, RTL'de elaborasyon/çalışma-anı doğrulamalı (3.9.3)**; değişiklik = minor sürüm + göç notu |
| LUT bütçelerinin şaşması | hedef cihaz seçimi, dürüstlük eşiğinin aşımı | Tüm sayılar Faz 0 spike + Faz 1 kalibrasyonuna kadar hipotez; CI alan regresyonu **faz-hizalı konfiglerle** bağlayıcı (3.5); >%25 sapma → alan-hileleri listesine dönüş; **BASE ≤ ~400 LUT4** eşiği aşılırsa tasarım gerekçesi yeniden tartışılır |
| fmax gerilemesi sessiz kalır | gecikme tablosu (3.6) geçersizleşir, CI yeşil kalırdı | **Konfig×aile başına asgari fmax eşiği CI'da bağlayıcı** (HX ≥48, UP5K ≥24, ECP5 ≥60 MHz — 6.9); trend takibi nightly, eşiğe %10 yaklaşma uyarısı |
| İki dilli sürüm kayması (SV ≠ VHDL) | sinsi davranış farkı | Ortak cocotb + üçlü diff her PR'da; yapısal ayna **mekanik `hdl-mirror` port-imza diff'iyle** + PR şablonu kuralıyla; **`port-bekliyor` açıkken release kesilemez** (Bölüm 5) |
| `ghdl-yosys-plugin` kırılganlığı | VHDL sentez/formal akışı kırılır | Plugin sürümü CI'da pinli; VHDL alan sayıları bilgilendirici, bağlayıcı sayılar SV akışından; nvc kırılırsa bloklamaz |
| FFI vararg tuzağı (özellikle ARM64) | altın modelde sessiz tip-terfi uyumsuzluğu | cffi (`ffi.cdef`) birincil; sabit-ariteli C shim harness yedeği baştan planda |
| Geri-basınç kilitlenmesi (ready zinciri × FULL_POLICY) | sistem donması | sby `no-deadlock` (sayaçlı adalet varsayımı; **BAD_MSG/BAD_UOP vakaları dahil — davranış 3.9'da spec'li olduğu için kanıtlanabilir**) + STALL modunda üretici tarafı zaman aşımı sayacı belgelenir; gerçek sonsuz-liveness kanıtlanamaz — sınırlı-adalet sözleşmesi belgeye yazılır |
| DROP modunda belirlenimcilik beklentisi | kullanıcı "bayt akışı ready'den bağımsız" sanır | Değişmez STALL/taşmasız koşullara daraltıldı; DROP için mesaj-bütünlüğü sözleşmesi + `drop-atomicity` formal görevi + mesaj-küme eşdeğerlik testi (6.5, 6.7) |
| Çalışma-anı `%s` semantiği (kim yazar, ne zaman geçerli) | veri yarışı | Faz 1–2'de yalnız ROM-`%s`; satır-içi varyantta **STR-FIFO + commit-sonrası-donmuş** sözleşmesi (3.9.6); parser modunda `%s`=tablo-ID; genel bellek portu çekirdeğe girmez |
| Tetik kaynağı başka saat bölgesinden gelir | çok-bitli arg'da bit tutarsızlığı (2FF yetmez) | Sözleşme: tetikler çekirdek saatinde (2.1); ihlal gereken yerde `kp_cdc_trig` req-ack adaptörü (Faz 3); async-FIFO senaryosunda iki bölgeli senkron-deassert reset (3.9.4) |
| ROM güncelleme = yeni bitstream | format değişikliği maliyetli | v1'de kabul edilir ve Limitations'a yazılır; `G_ROM_WRITABLE` Faz 3'te değerlendirilir |
| 16/32-bit semantiği ihlali | altın modelle sistematik uyumsuzluk | Sözleşme Faz 0'da tek cümleyle donduruldu (2.1); `*` argümanlarının 32-bit-işaretli yorumu da spec'te (3.2.1); `k_fmtgen` tek yetkili — `size` bitini o üretir, elle µop yazımı belgelenmez; sınır vektörleri sabit |
| `G_ARGC_MAX` yeterliliği (4 vs 8) | uzun log çerçeveleri sığmaz — **`*` yuvaları arity'yi şişirir (3.2.1)** | µop arg-slot alanı 3 bit (≤8) — generic 4'te başlar, ISA değişmeden 8'e çıkabilir; `k_fmtgen` taşan mesajı üretimde reddeder, `messages_report.md` yuva envanteriyle karar |
| `out_last` anlamı | tüketici sözleşmesi belirsizliği | Karar: **mesaj sonu** (satır sonu `\n` formatın işidir); sentetik EOM da `out_last` üretir (3.9.2); `integration.md`'ye yazılır |
| Drop telemetrisi nerede raporlanır | gözlemlenebilirlik | `dropped_cnt` hem native durum portunda hem Faz 3 register haritasında (`STATUS` sticky biti + sayaç); **retrigger-penceresi düşüşleri de aynı sayaçta (3.9.4)**; `err_cnt` BAD_MSG/BAD_UOP için ayrı |

---

*Kaynak temeli: `src/k_printf.c` (383 satır — tek `fmt_int` çekirdeği, üç dallı yerleşim, `0`+precision kuralı, `%#o` istisnası, INT_MIN-güvenli negasyon, bilinmeyen-belirteç sözleşmesi) satır düzeyinde RTL planına izdüşürüldü; `tests/fuzz_k_printf.c`'nin 8-bayt çözme şeması ve `test_optout.c` konfig testleri doğrulama planının çekirdeği yapıldı; `examples/uart_ringbuf.c` sistem tarafının provası olarak birebir eşlendi. CI tarafında sıfırdan başlandığı dürüstçe kaydedildi: `.github/workflows/` ve `tools/` bugün repoda yok — Faz 0 bunları kurar, HDL işleri üstüne eklenir. Kilit kurgu: doğrulama zinciri C kütüphanesine bağlanır — altın model tektir, iki HDL ona ve birbirine karşı koşar, formal yalnız simülasyonun ulaşamadığı protokol/kilitlenme uzayını kapatır; hata/reset/sınır-durum davranışları (Bölüm 3.9) spec'e yazıldığı için bu formal görevler kanıt üretebilir. Stil: `k_printf_v2_gelistirme_notu.md` fazlı/tablolu formatı.*