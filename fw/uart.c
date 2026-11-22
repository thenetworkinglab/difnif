// DifNif FPGA-only firmware: the log on the serial port
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#include "fw.h"

// A ring buffer, sent a byte at a time by uart_poll() from the main loop, so
// a log line doesn't hold up the host (a byte takes 10 us at 1 Mbaud). When
// it's full, putch waits.
static char ring[512];
static unsigned head, tail;

void uart_poll(void)
{
    if (head != tail && (UART_STAT & UART_TXRDY)) {
        UART = (uint8_t)ring[tail];
        tail = (tail + 1) % sizeof ring;
    }
}

void uart_flush(void)
{
    while (head != tail) uart_poll();
}

void putch(char c)
{
    unsigned next;
    if (c == '\n') putch('\r');
    next = (head + 1) % sizeof ring;
    while (next == tail) uart_poll();
    ring[head] = c;
    head = next;
}

void puts_(const char *s)
{
    while (*s) putch(*s++);
}

void puthex(uint32_t v, int digits)
{
    while (digits-- > 0) putch("0123456789ABCDEF"[(v >> (4 * digits)) & 15]);
}

void putdec(uint32_t v)
{
    char b[10];
    int n = 0;
    do {
        b[n++] = (char)('0' + v % 10);   // libgcc's divide: RV32I has none
        v /= 10;
    } while (v);
    while (n) putch(b[--n]);
}

void logline(const char *s, uint32_t v)
{
    puts_(s);
    puthex(v, 8);
    putch('\n');
}
