// DifNif FPGA-only firmware: the log on the serial port
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#include "fw.h"

void putch(char c)
{
    if (c == '\n') putch('\r');
    while (!(UART & UART_TXRDY)) {
    }
    UART = (uint8_t)c;
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
