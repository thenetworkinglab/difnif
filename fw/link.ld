/* DifNif FPGA-only firmware: everything in the SoC's 10 KB of RAM (soc.v RAM_WORDS) */
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 10K }
ENTRY(_start)
SECTIONS {
    .text : { *(.text.start) *(.text*) } > RAM
    .rodata : { *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
/* The stack grows down from the top of RAM into what's left. At 92 bytes
   the firmware overwrote its own data (seen in simulation); keep 1 KB. */
ASSERT(_stack_top - _bss_end >= 1024, "firmware too big: less than 1 KB left for the stack")
