# DifNif FPGA-only firmware for the SoC's PicoRV32 (verilog/soc.v)
#
#   make          builds ../verilog/fw.hex, which the FPGA build loads into RAM
#
# Needs a RISC-V cross compiler, riscv64-elf-gcc (Homebrew) or set CROSS.
#
# This file is part of a fork of DifNif; CERN-OHL-S-2.0.

CROSS ?= riscv64-elf-
CC = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
SIZE = $(CROSS)size
CFLAGS = -march=rv32ic -mabi=ilp32 -Os -ffreestanding -fno-builtin -nostdlib \
         -ffunction-sections -fdata-sections -Wall -Wextra -std=c11
# make TRACE=1: the trace on from start-up (for simulation, or a bench run
# where you can't type 'v' in time)
TRACE ?= 0
CFLAGS += -DTRACE_AT_START=$(TRACE)
# make EXTRA=-D...: more defines for a test build
CFLAGS += $(EXTRA)
LDFLAGS = -Wl,-T,link.ld -Wl,--gc-sections -Wl,--no-warn-rwx-segments -nostartfiles -lgcc
SRCS = start.S main.c uart.c sd.c fat.c esdi.c
RAM_WORDS = 2560

all: ../verilog/fw.hex

fw.elf: $(SRCS) hw.h fw.h link.ld
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(LDFLAGS)
	$(SIZE) $@

fw.bin: fw.elf
	$(OBJCOPY) -O binary $< $@

../verilog/fw.hex: fw.bin bin2hex.py
	python3 bin2hex.py $< $@ $(RAM_WORDS)

clean:
	rm -f fw.elf fw.bin

.PHONY: all clean
