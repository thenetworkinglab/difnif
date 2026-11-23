// DifNif FPGA-only firmware: shared declarations
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#ifndef FW_H
#define FW_H

#include <stdint.h>
#include "hw.h"

// The FPGA-only build's version: the release date and a count of releases
// that day, as verilog/version.vh's FPGA_CPU_VERSION (the two normally match)
#define FW_VERSION "v2026.11.22-1"

// uart.c: the log
void putch(char c);
void puts_(const char *s);
void puthex(uint32_t v, int digits);
void putdec(uint32_t v);
void logline(const char *s, uint32_t v);   // "s" and v in hex, then a newline
void uart_poll(void);              // sends a byte of the log if it can
void uart_flush(void);

// sd.c
extern uint32_t sd_status;         // sdhost status after the last command
extern int sd_high_capacity;       // block addresses (1) or byte addresses (0)
int sd_init(void);                 // 0 on success, else a step number
int sd_cmd(uint32_t idx, uint32_t arg, uint32_t flags);   // 0 or the error bits
int sd_read_cpu(uint32_t lba);     // one block into the processor's buffer
int sd_start_read(uint32_t lba, uint32_t n);    // up to n blocks to the sector buffer (CMD18)
int sd_start_write(uint32_t lba, uint32_t n);   // n blocks from it
int sd_data_busy(void);
int sd_stop(int multi);            // end a transfer (CMD12 if multi)
int sd_check(void);                // 0 if the card answers and is ready for transfers
uint8_t cbuf_byte(int i);          // byte i of that block
uint16_t cbuf_u16(int i);
uint32_t cbuf_u32(int i);

// fat.c: finding the disk image
extern uint32_t img_lba;           // first card block of disk0.img
extern uint32_t img_blocks;        // its length in blocks
#define IMG_RUNS 32                // pieces of disk0.img the firmware can follow
extern uint32_t img_runs;          // how many it's in
uint32_t img_map(uint32_t rba, uint32_t *left);   // card block, and blocks to its run's end
extern int img_exfat;              // on exFAT (1) or FAT32 (0)
int find_image(void);              // 0 if found and contiguous, else a reason

// esdi.c: the drive
void esdi_run(uint32_t blocks);    // never returns; blocks 0: no disk image
void show_status(void);            // main.c: the start-up summary
uint32_t card_restart(void);       // main.c: start the card again; disk0.img's blocks, or 0

#endif
