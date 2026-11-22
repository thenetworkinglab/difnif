// DifNif FPGA-only firmware: the SoC's registers (verilog/soc.v)
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#ifndef HW_H
#define HW_H

#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(a))

// Mailbox registers, numbered as the Teensy's (verilog/teensy.v)
#define MBOX(n)      REG32(0x10000000u + 4u * (n))
#define MB_TEST      0
#define MB_FLAGS     1
#define MB_ATN       2
#define MB_ISR       3
#define MB_CIFR      4
#define MB_SIFR      5
#define MB_DREG      6
#define MB_POS01     7
#define MB_POS23     8
#define MB_POS4      9
#define MB_VER_YEAR  10
#define MB_VER_DATE  11
#define MB_VER_COUNT 12
#define MB_VARIANT   13
#define MB_CTRL      15

// SD host controller (verilog/sdhost.v)
#define SD(n)        REG32(0x10000100u + 4u * (n))
#define SD_CTRL      0
#define SD_ARG       1
#define SD_CMD       2
#define SD_BLKCNT    3
#define SD_STATUS    4
#define SD_RESP0     5

#define SDC_DIV(n)   (n)
#define SDC_BUS4     (1u << 8)
#define SDC_FREE     (1u << 9)
#define SDC_LATE     (1u << 10)
#define SDC_ABORT    (1u << 16)

#define R_NONE       0
#define R_SHORT      (1u << 6)
#define R_LONG       (2u << 6)
#define R_BUSY       (1u << 8)
#define R_NOCRC      (1u << 9)
#define D_READ       (1u << 10)
#define D_WRITE      (2u << 10)
#define C_INITCLK    (1u << 12)

#define SDS_CMD_BUSY   (1u << 0)
#define SDS_DATA_BUSY  (1u << 1)
#define SDS_CMD_ERRS   (7u << 2)
#define SDS_DATA_ERRS  (15u << 5)
#define SDS_DETECT     (1u << 9)

// Bridge to the sector buffer (verilog/sdbridge.v), and the route to the
// processor's own buffer
#define BR_CTRL      REG32(0x10000200u)
#define BR_ARM       REG32(0x10000204u)
#define BR_STATUS    REG32(0x10000208u)
#define BRC_WRITE    (1u << 0)
#define BRC_RESTART  (1u << 1)
#define BRC_CLRFAIL  (1u << 2)
#define BRC_CPU      (1u << 3)
#define BRC_REWIND   (1u << 4)

// Serial port, LEDs, timer
#define UART         REG32(0x10000300u)   // reading takes a received byte
#define UART_STAT    REG32(0x1000030Cu)   // the same bits, reading takes nothing
#define UART_TXRDY   (1u << 8)
#define UART_RXHAVE  (1u << 9)
#define LEDS         REG32(0x10000304u)
#define MICROS       REG32(0x10000308u)

// The processor's sector buffer: 256 words of 16 bits, 4 bytes apart
#define CBUF(i)      REG32(0x20000000u + 4u * (i))

#endif
