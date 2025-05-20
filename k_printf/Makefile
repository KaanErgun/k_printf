CC = msp430-gcc
CFLAGS = -mmcu=msp430g2553 -Iinclude

all: example.elf

example.elf: src/k_printf.c examples/main.c
	$(CC) $(CFLAGS) -o $@ $^

clean:
	rm -f example.elf