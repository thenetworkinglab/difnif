// DifNif FPGA-only firmware: shared declarations
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#ifndef FW_H
#define FW_H

#include <stdint.h>
#include "hw.h"

#define FW_VERSION "cpu-dev"

// uart.c: the log
void putch(char c);
void puts_(const char *s);
void puthex(uint32_t v, int digits);
void putdec(uint32_t v);
void logline(const char *s, uint32_t v);   // "s" and v in hex, then a newline

// sd.c
extern uint32_t sd_status;         // sdhost status after the last command
extern int sd_high_capacity;       // block addresses (1) or byte addresses (0)
int sd_init(void);                 // 0 on success, else a step number
int sd_cmd(uint32_t idx, uint32_t arg, uint32_t flags);   // 0 or the error bits
int sd_read_cpu(uint32_t lba);     // one block into the processor's buffer
uint8_t cbuf_byte(int i);          // byte i of that block
uint16_t cbuf_u16(int i);
uint32_t cbuf_u32(int i);

// fat.c: finding the disk image
extern uint32_t img_lba;           // first card block of disk0.img
extern uint32_t img_blocks;        // its length in blocks
int find_image(void);              // 0 if found and contiguous, else a reason

#endif
