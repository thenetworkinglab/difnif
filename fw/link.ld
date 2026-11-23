/* DifNif FPGA-only firmware: everything in the SoC's 12 KB of RAM (soc.v RAM_WORDS) */
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 12K }
ENTRY(_start)
SECTIONS {
    .text : { *(.text.start) *(.text*) } > RAM
    .rodata : { *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
/* The stack grows down from the top of RAM into what's left. At 92 bytes
   the firmware overwrote its own data (seen in simulation). The deepest
   call chain, a card restart in the middle of a transfer (esdi_run, retry
   or next_run, card_start, card_restart, find_image, fat_entry,
   sd_read_cpu, sd_cmd, with logging), needs about 450 bytes by gcc's
   -fstack-usage (22 November); keep 768. */
ASSERT(_stack_top - _bss_end >= 768, "firmware too big: less than 768 bytes left for the stack")
