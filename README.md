# k_printf

🔧 Lightweight `printf` implementation for MSP430 microcontrollers.  
🎯 Designed for low-memory embedded systems — no `malloc`, no `vsnprintf`, no problem.

![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-MSP430-blue)
![Language](https://img.shields.io/badge/language-C-lightgrey)

---

## ✨ Features

- Supports format specifiers: `%d`, `%u`, `%x`, `%c`, `%s`
- No dynamic memory usage
- Easy to integrate: works with any `putc()` function
- Tiny code size, ideal for MSP430 projects

---

## 🚀 Quick Start

### 🧩 Step 1: Initialize with your output function

```c
void uart_putc(char c) {
    while (!(IFG2 & UCA0TXIFG));
    UCA0TXBUF = c;
}

k_printf_init(uart_putc);
```

### 🖨️ Step 2: Print formatted text

```c
k_printf("Hello, %s! Value: %d (0x%x)\n", "world", 42, 42);
```

---

## 🧪 Supported Format Specifiers

| Specifier | Meaning           | Example Output |
|-----------|-------------------|----------------|
| `%d`      | Signed decimal    | `-123`         |
| `%u`      | Unsigned decimal  | `123`          |
| `%x`      | Hexadecimal       | `0x7b`         |
| `%c`      | Character          | `A`            |
| `%s`      | String             | `Hello`        |

---

## 📁 Project Structure

```
k_printf/
├── include/       # Public header
├── src/           # Core implementation
├── examples/      # Sample usage for MSP430
├── LICENSE
├── README.md
└── Makefile
```

---

## 🛠️ Building

```bash
make
```

You can modify `CFLAGS` and `MCU` in the `Makefile` to suit your device.

---

## 📜 License

MIT © [Kaan Ergun](https://github.com/KaanErgun)

---

## 💡 Why k_printf?

Because embedded systems deserve beautiful debugging too —  
without the cost of the kitchen sink.
